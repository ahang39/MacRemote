#!/usr/bin/env python3
"""Bundle and audit the Mach-O dependencies of a staged MacRemote app."""

import argparse
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
from collections import deque
from pathlib import Path

SYSTEM_LIBRARIES = ("/System/Library/", "/usr/lib/", "/Library/Apple/System/")


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True).strip()


def dependencies(binary):
    lines = run("/usr/bin/otool", "-L", binary).splitlines()
    first_dependency = 2 if binary.suffix == ".dylib" else 1
    return [
        line.strip().split(" (compatibility version", 1)[0]
        for line in lines[first_dependency:]
    ]


def rpaths(binary):
    commands = run("/usr/bin/otool", "-l", binary)
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)", commands)


def resolve(name, origin, executable, search_paths):
    if name.startswith("@loader_path/"):
        candidates = [origin.parent / name.removeprefix("@loader_path/")]
    elif name.startswith("@executable_path/"):
        candidates = [executable.parent / name.removeprefix("@executable_path/")]
    elif name.startswith("@rpath/"):
        relative = name.removeprefix("@rpath/")
        candidates = [directory / relative for directory in (origin.parent, *search_paths)]
    else:
        candidates = [Path(name)] if name.startswith("/") else []

    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError(f"Missing dylib {name}, requested by {origin}")


def relocate(binary, changes):
    arguments = []
    if binary.suffix == ".dylib":
        arguments.extend(("-id", "@loader_path/" + binary.name))
    for old, new in changes.items():
        if old != new:
            arguments.extend(("-change", old, new))
    for path in rpaths(binary):
        arguments.extend(("-delete_rpath", path))
    if arguments:
        run("/usr/bin/install_name_tool", *arguments, binary)


def audit(binary, framework_dir, executable_dir):
    for name in dependencies(binary):
        if name.startswith(SYSTEM_LIBRARIES):
            continue
        if name.startswith("@loader_path/"):
            target = binary.parent / name.removeprefix("@loader_path/")
        elif name.startswith("@executable_path/"):
            target = executable_dir / name.removeprefix("@executable_path/")
        else:
            raise RuntimeError(f"External dependency: {binary.name} loads {name}")

        if not target.resolve().is_relative_to(framework_dir) or not target.is_file():
            raise RuntimeError(f"Invalid bundled dependency: {binary.name} loads {name}")
    if rpaths(binary):
        raise RuntimeError(f"Runtime search paths remain in {binary}")


def minimum_macos(binary):
    commands = run("/usr/bin/xcrun", "vtool", "-show-build", binary)
    versions = re.findall(r"(?m)^\s*minos (\d+(?:\.\d+)+)[ \t]*$", commands)
    versions.extend(re.findall(
        r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)+)",
        commands,
    ))
    if not versions:
        raise RuntimeError(f"No macOS deployment target in {binary}")
    return max(tuple(map(int, version.split("."))) for version in versions)


def bundle(app, build, dependency_prefix):
    executable_dir = app / "Contents/MacOS"
    framework_dir = app / "Contents/Frameworks"
    if not (executable_dir / "macremote-server").is_file():
        raise RuntimeError("Missing native RDP server binary")
    framework_dir.mkdir()

    search_paths = [
        build / path for path in
        ("server/shadow", "server/common", "winpr/tools", "winpr/libwinpr", "libfreerdp")
    ]
    search_paths.append(dependency_prefix / "lib")

    executables = sorted(path for path in executable_dir.iterdir() if path.is_file())
    pending = deque((path, path, path) for path in executables)
    sources = {}
    while pending:
        origin, target, executable = pending.popleft()
        prefix = "@loader_path/" if target != executable else "@executable_path/../Frameworks/"
        changes = {}
        for name in dependencies(origin):
            if name.startswith(SYSTEM_LIBRARIES):
                continue
            source = resolve(name, origin, executable, search_paths)
            if not (source.is_relative_to(build) or source.is_relative_to(dependency_prefix)):
                raise RuntimeError(f"Dylib outside private runtime: {source}")
            basename = Path(name).name
            if basename in sources:
                prior = sources[basename]
                if source != prior and hashlib.sha256(source.read_bytes()).digest() != (
                    hashlib.sha256(prior.read_bytes()).digest()
                ):
                    raise RuntimeError(f"Conflicting dylibs named {basename}: {prior} and {source}")
            else:
                sources[basename] = source
                copy = framework_dir / basename
                shutil.copy2(source, copy)
                pending.append((source, copy, executable))
            changes[name] = prefix + basename
        relocate(target, changes)

    # WinPR loads this provider with dlopen, outside the Mach-O dependency graph.
    crypto = sources["libcrypto.3.dylib"]
    source = crypto.parent / "ossl-modules/legacy.dylib"
    plugin = framework_dir / "ossl-modules/legacy.dylib"
    plugin.parent.mkdir()
    shutil.copy2(source, plugin)
    changes = {}
    for name in dependencies(plugin):
        if name.startswith(SYSTEM_LIBRARIES):
            continue
        provider_crypto = resolve(name, source, executables[0], search_paths)
        if provider_crypto != crypto:
            raise RuntimeError(f"OpenSSL provider links a different libcrypto: {provider_crypto}")
        changes[name] = "@loader_path/../libcrypto.3.dylib"
    relocate(plugin, changes)

    libraries = sorted(framework_dir.rglob("*.dylib"))
    binaries = [*executables, *libraries]
    for binary in binaries:
        audit(binary, framework_dir, executable_dir)

    plist = app / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    target = tuple(map(int, info["LSMinimumSystemVersion"].split(".")))
    if target != (14, 0):
        raise RuntimeError("Unexpected deployment target: " + info["LSMinimumSystemVersion"])
    for binary in binaries:
        minimum = minimum_macos(binary)
        if minimum > target:
            raise RuntimeError(f"{binary.name} requires macOS {'.'.join(map(str, minimum))}; target is 14.0")
    print(f"MACREMOTE_MINIMUM_MACOS={info['LSMinimumSystemVersion']}")
    print(f"BUNDLED_DYLIB_COUNT={len(libraries)}")
    print(f"BUNDLED_DYLIB_BYTES={sum(path.stat().st_size for path in libraries)}")
    print("BUNDLED_RUNTIME_SELF_CONTAINED=YES")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path)
    parser.add_argument("--freerdp-build", type=Path, required=True)
    parser.add_argument("--dependency-prefix", type=Path, required=True)
    args = parser.parse_args()
    try:
        bundle(args.app.resolve(), args.freerdp_build.resolve(), args.dependency_prefix.resolve())
    except (OSError, KeyError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"MacRemote bundling failed: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
