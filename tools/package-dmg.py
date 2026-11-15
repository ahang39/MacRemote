#!/usr/bin/env python3
"""Create and verify a license-audited, ad-hoc signed macOS DMG."""
from __future__ import annotations

import argparse
import hashlib
import shutil
import subprocess
import tempfile
from pathlib import Path


FORBIDDEN = ("libavcodec", "libavutil", "libavformat", "libswscale", "libswresample", "libx264", "libx265")
REQUIRED_LICENSES = (
    "MacRemote-PolyForm-Noncommercial-1.0.0.txt",
    "THIRD_PARTY_NOTICES.md",
    "FreeRDP-Apache-2.0.txt",
    "OpenSSL-License.txt",
    "Opus-COPYING.txt",
    "json-c-COPYING.txt",
)


def run(*args: str) -> str:
    result = subprocess.run(args, text=True, capture_output=True, check=True)
    return (result.stdout or result.stderr).strip()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--arch", required=True, choices=("arm64", "x86_64"))
    args = parser.parse_args()
    app = args.app.resolve()
    out = args.out.resolve()
    if app.suffix != ".app" or not (app / "Contents/MacOS/MacRemote").is_file():
        raise SystemExit("Not a MacRemote application bundle")

    libroot = app / "Contents/Frameworks"
    libs = sorted(libroot.rglob("*.dylib"))
    for lib in libs:
        if any(lib.name.lower().startswith(name) for name in FORBIDDEN):
            raise SystemExit("Forbidden FFmpeg/GPL dependency in release bundle: " + lib.name)

    legal = app / "Contents/Resources/Licenses"
    for name in REQUIRED_LICENSES:
        if not (legal / name).is_file():
            raise SystemExit("Required license/notice missing: " + name)

    executables = [app / "Contents/MacOS/MacRemote", app / "Contents/MacOS/macremote-server"]
    for executable in [*executables, *libs]:
        arches = run("lipo", "-archs", str(executable)).split()
        if args.arch not in arches:
            raise SystemExit(f"Architecture {args.arch} missing in {executable.name}: {arches}")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    signature = run("codesign", "-dv", "--verbose=4", str(app))
    if "Signature=adhoc" not in signature:
        raise SystemExit("Not ad-hoc signed. Use MACREMOTE_SIGN_IDENTITY=-")

    if out.exists():
        raise SystemExit("Refusing to overwrite existing DMG: " + str(out))
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="macremote-dmg-") as temp:
        stage = Path(temp) / "volume"
        stage.mkdir()
        shutil.copytree(app, stage / "MacRemote.app", symlinks=True)
        (stage / "Applications").symlink_to("/Applications")
        (stage / "INSTALL.txt").write_text(
            "MacRemote: Windows Remote Desktop for macOS\\n\\n"
            "Drag MacRemote.app to Applications.\\n"
            "On the first launch of this ad-hoc signed build, macOS may block the app.\\n"
            "Open System Settings > Privacy & Security and choose Open Anyway after a launch attempt.\\n"
            "Grant Screen & System Audio Recording, then start the RDP service.\\n"
            "Do not expose RDP directly to the public Internet.\\n"
            "Source, license and reports: https://github.com/ahang39/MacRemote\\n"
        )
        run("hdiutil", "create", "-volname", "MacRemote", "-srcfolder", str(stage),
            "-format", "UDZO", "-imagekey", "zlib-level=9", "-ov", str(out))
    run("hdiutil", "verify", str(out))
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"DMG={out}")
    print(f"ARCH={args.arch}")
    print(f"LIBRARIES={len(libs)}")
    print(f"SHA256={digest}")


if __name__ == "__main__":
    main()
