#!/usr/bin/env python3
"""Create and verify a license-audited macOS DMG (ad-hoc or fixed release identity)."""
from __future__ import annotations

import argparse
import hashlib
import plistlib
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
    parser.add_argument("--release-identity", help="Require this non-ad-hoc code signing identity")
    args = parser.parse_args()
    app = args.app.resolve()
    out = args.out.resolve()
    if app.suffix != ".app" or not (app / "Contents/MacOS/MacRemote").is_file():
        raise SystemExit("Not a MacRemote application bundle")

    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    minimum = info["LSMinimumSystemVersion"]
    libroot = app / "Contents/Frameworks"
    libs = sorted(libroot.rglob("*.dylib"))
    for lib in libs:
        if any(lib.name.lower().startswith(name) for name in FORBIDDEN):
            raise SystemExit("Forbidden FFmpeg/GPL dependency in release bundle: " + lib.name)

    legal = app / "Contents/Resources/Licenses"
    for name in REQUIRED_LICENSES:
        if not (legal / name).is_file():
            raise SystemExit("Required license/notice missing: " + name)

    executables = [path for path in (app / "Contents/MacOS").iterdir() if path.is_file()]
    for executable in [*executables, *libs]:
        arches = run("lipo", "-archs", str(executable)).split()
        if args.arch not in arches:
            raise SystemExit(f"Architecture {args.arch} missing in {executable.name}: {arches}")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    signature = run("codesign", "-dv", "--verbose=4", str(app))
    if args.release_identity:
        if "Signature=adhoc" in signature or f"Authority={args.release_identity}" not in signature:
            raise SystemExit(f"Expected fixed release signer {args.release_identity}; refusing package")
    elif "Signature=adhoc" not in signature:
        raise SystemExit("Not ad-hoc signed. Use --release-identity for the public release signer")

    if out.exists():
        raise SystemExit("Refusing to overwrite existing DMG: " + str(out))
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="macremote-dmg-") as temp:
        stage = Path(temp) / "volume"
        stage.mkdir()
        shutil.copytree(app, stage / "MacRemote.app", symlinks=True)
        (stage / "Applications").symlink_to("/Applications")
        signature_note = (
            "This build is signed with a fixed self-signed release certificate (not Apple notarized)."
            if args.release_identity else
            "This build is ad-hoc signed (not Apple notarized)."
        )
        (stage / "INSTALL.txt").write_text(
            "\n".join([
                "MacRemote: Windows Remote Desktop for macOS",
                "",
                "Drag MacRemote.app to Applications.",
                signature_note,
                "On first launch, macOS may block the app. After trying to launch it,",
                "open System Settings > Privacy & Security and choose Open Anyway.",
                "Open MacRemote from Applications.",
                "Connect using your macOS account credentials.",
                "Use the MacRemote menu bar to configure the server and bandwidth.",
                "Grant Screen & System Audio Recording, then start the RDP service.",
                "Do not expose RDP directly to the public Internet.",
                "Source, license and reports: https://github.com/ahang39/MacRemote",
                "",
            ]),
            encoding="utf-8",
        )
        run("hdiutil", "create", "-volname", "MacRemote", "-srcfolder", str(stage),
            "-format", "UDZO", "-imagekey", "zlib-level=9", "-ov", str(out))
    run("hdiutil", "verify", str(out))
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    print(f"DMG={out}")
    print(f"ARCH={args.arch}")
    print(f"MINIMUM_MACOS={minimum}")
    print(f"LIBRARIES={len(libs)}")
    print(f"SHA256={digest}")


if __name__ == "__main__":
    main()
