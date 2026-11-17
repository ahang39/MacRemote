#!/usr/bin/env python3
"""Build pinned, private macOS 14 runtime dependencies without Homebrew libraries."""

import hashlib
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BASE = ROOT / ".build"
ARCH = subprocess.check_output(["uname", "-m"], text=True).strip()
if ARCH not in ("arm64", "x86_64"):
    raise SystemExit(f"Unsupported architecture: {ARCH}")
PREFIX = BASE / ARCH / "prefix"
BUILD = BASE / ARCH / "build"
SOURCES = BASE / "sources"
DOWNLOADS = BASE / "downloads"
JOBS = os.environ.get("MACREMOTE_BUILD_JOBS", "4")
MINIMUM = "14.0"
PACKAGES = {
    "openssl-3.5.9": (
        "https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz",
        "603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a",
    ),
    "opus-1.6.1": (
        "https://ftp.osuosl.org/pub/xiph/releases/opus/opus-1.6.1.tar.gz",
        "6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1",
    ),
    "json-c-0.19": (
        "https://s3.amazonaws.com/json-c_releases/releases/json-c-0.19.tar.gz",
        "37ad0249902e301bd9052bf712e511fcc6acff4ecaad4b5900aad9ce564e26de",
    ),
}
ENV = os.environ.copy()
ENV["MACOSX_DEPLOYMENT_TARGET"] = MINIMUM
ENV["PKG_CONFIG_LIBDIR"] = str(PREFIX / "lib/pkgconfig")
ENV["PKG_CONFIG_PATH"] = ""


def run(*args, cwd=None, env=ENV):
    subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)


def source(name):
    url, checksum = PACKAGES[name]
    archive = DOWNLOADS / f"{name}.tar.gz"
    if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        DOWNLOADS.mkdir(parents=True, exist_ok=True)
        temporary = archive.with_suffix(".download")
        try:
            run("curl", "--fail", "--location", "--retry", "3", "--output", temporary, url)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != checksum:
                raise RuntimeError(f"Checksum mismatch for {name}")
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    path = SOURCES / name
    if not (path / ".macremote-source-ready").is_file():
        path.mkdir(parents=True, exist_ok=True)
        run("tar", "-xzf", archive, "-C", path, "--strip-components=1")
        (path / ".macremote-source-ready").touch()
    return path


def cmake(name, extra):
    stamp = BUILD / f".{name}-installed"
    if stamp.exists():
        return
    source_dir = source(name)
    build_dir = BUILD / name
    run(
        "cmake", "-S", source_dir, "-B", build_dir, "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release", f"-DCMAKE_INSTALL_PREFIX={PREFIX}",
        f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MINIMUM}", f"-DCMAKE_OSX_ARCHITECTURES={ARCH}",
        "-DBUILD_SHARED_LIBS=ON", "-DBUILD_TESTING=OFF", *extra,
    )
    run("cmake", "--build", build_dir, "--parallel", JOBS)
    run("cmake", "--install", build_dir)
    stamp.touch()


def openssl():
    name = "openssl-3.5.9"
    stamp = BUILD / f".{name}-installed"
    if stamp.exists():
        return
    src = source(name)
    compiler = "darwin64-arm64-cc" if ARCH == "arm64" else "darwin64-x86_64-cc"
    local_env = ENV | {
        "CC": "clang",
        "CFLAGS": f"-mmacosx-version-min={MINIMUM}",
        "LDFLAGS": f"-mmacosx-version-min={MINIMUM}",
    }
    run(
        "perl", "./Configure", compiler, "shared", "no-tests", "no-docs", "no-apps",
        f"--prefix={PREFIX}", f"--openssldir={PREFIX / 'ssl'}", cwd=src, env=local_env,
    )
    run("make", f"-j{JOBS}", cwd=src, env=local_env)
    run("make", "install_sw", cwd=src, env=local_env)
    stamp.touch()


def main():
    BUILD.mkdir(parents=True, exist_ok=True)
    PREFIX.mkdir(parents=True, exist_ok=True)
    openssl()
    cmake("opus-1.6.1", ["-DOPUS_BUILD_TESTING=OFF", "-DOPUS_BUILD_PROGRAMS=OFF"])
    cmake("json-c-0.19", ["-DDISABLE_WERROR=ON"])
    required = (
        "lib/libssl.3.dylib", "lib/libcrypto.3.dylib",
        "lib/libopus.0.dylib", "lib/libjson-c.5.dylib",
        "lib/ossl-modules/legacy.dylib", "lib/pkgconfig/opus.pc",
    )
    for name in required:
        if not (PREFIX / name).is_file():
            raise RuntimeError(f"Missing private dependency: {name}")
    print(f"MACREMOTE_DEPENDENCY_PREFIX={PREFIX}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        sys.exit(f"Private dependency build failed: {error}")
