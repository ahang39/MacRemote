#!/bin/zsh
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cache="${MACREMOTE_BUILD_CACHE:-$HOME/Library/Caches/MacRemote}"
output="$cache/product"
sign_identity="${MACREMOTE_SIGN_IDENTITY:--}"
target_arch="${MACREMOTE_TARGET_ARCH:-$(uname -m)}"
case "$target_arch" in
  arm64|x86_64) ;;
  *) echo "Unsupported architecture: $target_arch" >&2; exit 2 ;;
esac
if [[ "$(uname -m)" != "$target_arch" ]]; then
  echo "Build natively on a $target_arch Mac to match third-party dependencies." >&2
  exit 2
fi
version="3.33.1"
expected_commit="65bcca1913a28cbdd7eb913599f692bd2b707991"

mkdir -p "$output"
work="$(mktemp -d "$output/.MacRemote-build-XXXXXXXX")"
native_build="$work/native-build"
bootstrap=""
cleanup() {
  /bin/rm -rf -- "$work"
  if [[ -n "$bootstrap" ]]; then
    /bin/rm -rf -- "$bootstrap"
  fi
}
trap cleanup EXIT

freerdp_source="${FREERDP_SOURCE_ROOT:-$cache/m1/FreeRDP-$version}"
freerdp_build="${FREERDP_BUILD_ROOT:-$cache/m1/freerdp-e2e-build}"

# On a clean Mac, build the pinned FreeRDP source in a disposable directory.
# A persistent FreeRDP repository is never required by the final App.
if [[ ! -d "$freerdp_source" || ! -f "$freerdp_build/CMakeCache.txt" ]]; then
  bootstrap="$(mktemp -d "$cache/.freerdp-temporary-XXXXXXXX")"
  freerdp_source="$bootstrap/source"
  freerdp_build="$bootstrap/build"
  echo "Temporarily bootstrapping FreeRDP $version..."
  git clone --depth 1 --branch "$version" --recurse-submodules \
    https://github.com/FreeRDP/FreeRDP.git "$freerdp_source"
  if [[ "$(git -C "$freerdp_source" rev-parse HEAD)" != "$expected_commit" ]]; then
    echo "Pinned FreeRDP commit mismatch; refusing to build." >&2
    exit 2
  fi
  # FreeRDP's Opus pkg-config target exports include/opus rather than
  # include; add the parent so #include <opus/opus.h> resolves on clean builds.
  opus_include="$(pkg-config --variable=includedir opus 2>/dev/null || true)"
  if [[ -z "$opus_include" || ! -f "$opus_include/opus/opus.h" ]]; then
    echo "Opus headers required to rebuild FreeRDP" >&2
    exit 2
  fi
  cmake -S "$freerdp_source" -B "$freerdp_build" -G Ninja \
    -DCMAKE_C_FLAGS="-I$opus_include" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_SHARED_LIBS=ON -DWITH_SERVER=ON -DWITH_SHADOW=ON \
    -DWITH_CLIENT=OFF -DWITH_CLIENT_SDL=OFF -DWITH_SAMPLE=OFF -DWITH_X11=OFF \
    -DWITH_APPLE_VIDEOTOOLBOX=ON -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF -DWITH_OPUS=ON -DWITH_OPENSSL=ON \
    -DCHANNEL_CLIPRDR_SERVER=ON
fi

for name in \
  freerdp-3.33.1-karabiner-modifier-flags.patch \
  freerdp-3.33.1-macremote-event-filter.patch \
  freerdp-3.33.1-disconnect-key-reset.patch \
  freerdp-3.33.1-macremote-clipboard-hooks.patch \
  freerdp-3.33.1-gfx-capability-diagnostics.patch \
  freerdp-3.33.1-shadow-input-priority.patch \
  freerdp-3.33.1-mac-cursor-feedback.patch \
  freerdp-3.33.1-shadow-cert-log.patch; do
  patch="$repo/patches/$name"
  if ! git -C "$freerdp_source" apply --reverse --check "$patch" 2>/dev/null; then
    if git -C "$freerdp_source" apply --check "$patch"; then
      git -C "$freerdp_source" apply "$patch"
    else
      echo "Pinned FreeRDP patch failed: $name" >&2
      exit 2
    fi
  fi
done

cmake --build "$freerdp_build" --parallel "${MACREMOTE_BUILD_JOBS:-4}" \
  --target freerdp-shadow freerdp-shadow-subsystem-impl cliprdr-server
cmake -S "$repo" -B "$native_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DFREERDP_SOURCE_ROOT="$freerdp_source" \
  -DFREERDP_BUILD_ROOT="$freerdp_build"
cmake --build "$native_build" --parallel "${MACREMOTE_BUILD_JOBS:-4}"
ctest --test-dir "$native_build" --output-on-failure

# Validate app preference persistence without altering the user's defaults.
xcrun swiftc -O -parse-as-library -swift-version 5 \
  "$repo/apps/macos/ListenPortSettings.swift" \
  "$repo/tests/test_port_settings.swift" -o "$work/test-port-settings"
"$work/test-port-settings"

native="$native_build/macremote"
[[ -x "$native" ]] || { echo "MacRemote native server missing" >&2; exit 2; }

# Ad-hoc signing is supported; select an identity with MACREMOTE_SIGN_IDENTITY.
if [[ "$sign_identity" != "-" ]] && ! security find-identity -v -p codesigning | \
     grep -Fq "\"$sign_identity\""; then
  echo "Signing identity not found: $sign_identity" >&2
  exit 2
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="$output/MacRemote-$stamp.app"
[[ ! -e "$dest" ]] || { echo "Refusing to overwrite: $dest" >&2; exit 2; }

bundle="$work/MacRemote.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$repo/apps/macos/Info.plist" "$bundle/Contents/Info.plist"
cp "$native" "$bundle/Contents/MacOS/macremote-server"

# Include the corresponding project and third-party license texts in the App.
licenses="$bundle/Contents/Resources/Licenses"
mkdir -p "$licenses"
cp "$repo/LICENSE" "$licenses/MacRemote-PolyForm-Noncommercial-1.0.0.txt"
cp "$repo/THIRD_PARTY_NOTICES.md" "$licenses/THIRD_PARTY_NOTICES.md"
cp "$repo/licenses/third-party/"*.txt "$licenses/"
sdk="$(xcrun --show-sdk-path)"
xcrun swiftc -O -swift-version 5 \
  -target ${target_arch}-apple-macos14.0 -sdk "$sdk" \
  "$repo/tools/generate-icon.swift" -o "$work/generate-icon"
"$work/generate-icon" "$work/MacRemote.iconset"
iconutil --convert icns --output \
  "$bundle/Contents/Resources/MacRemote.icns" "$work/MacRemote.iconset"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target ${target_arch}-apple-macos14.0 -sdk "$sdk" \
  "$repo/apps/macos/MacRemoteApp.swift" \
  "$repo/apps/macos/ListenPortSettings.swift" \
  -o "$bundle/Contents/MacOS/MacRemote"

# Recursively bundle the FreeRDP and Homebrew library graph and remove all
# absolute build-cache / Homebrew references from their Mach-O load commands.
python3 "$repo/tools/bundle-runtime.py" "$bundle" \
  --freerdp-build "$freerdp_build"

for dylib in "$bundle"/Contents/Frameworks/*.dylib "$bundle"/Contents/Frameworks/ossl-modules/*.dylib; do
  codesign --force --options runtime --sign "$sign_identity" "$dylib" >/dev/null
done
codesign --force --options runtime \
  --entitlements "$repo/apps/macos/server-dev.entitlements" \
  --sign "$sign_identity" "$bundle/Contents/MacOS/macremote-server"
codesign --force --options runtime --sign "$sign_identity" \
  "$bundle/Contents/MacOS/MacRemote"
codesign --force --options runtime --sign "$sign_identity" "$bundle"
codesign --verify --deep --strict --verbose=2 "$bundle"
plutil -lint "$bundle/Contents/Info.plist"
"$bundle/Contents/MacOS/macremote-server" version
"$bundle/Contents/MacOS/macremote-server" doctor
[[ -s "$bundle/Contents/Resources/MacRemote.icns" ]] || {
  echo "App icon is missing" >&2; exit 2
}
mv -n "$bundle" "$dest"
echo "MACREMOTE_APP=$dest"
echo "Standalone App: FreeRDP and all transitive dylibs embedded."
echo "Signed with: $sign_identity"
