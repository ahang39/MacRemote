#!/bin/zsh
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
build_root="$repo/.build"
output="$build_root/output"
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
work="$(mktemp -d "$build_root/.app-build-XXXXXXXX")"
native_build="$work/native-build"
trap '/bin/rm -rf -- "$work"' EXIT

python3 "$repo/tools/bootstrap-deps.py"
dependency_prefix="$build_root/$target_arch/prefix"
export PKG_CONFIG_LIBDIR="$dependency_prefix/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export MACOSX_DEPLOYMENT_TARGET=14.0

patches=(
  freerdp-3.33.1-karabiner-modifier-flags.patch
  freerdp-3.33.1-macremote-event-filter.patch
  freerdp-3.33.1-disconnect-key-reset.patch
  freerdp-3.33.1-macremote-clipboard-hooks.patch
  freerdp-3.33.1-gfx-capability-diagnostics.patch
  freerdp-3.33.1-shadow-input-priority.patch
  freerdp-3.33.1-h264-presentation.patch
  freerdp-3.33.1-live-avc420-bitrate.patch
  freerdp-3.33.1-mac-cursor-feedback.patch
  freerdp-3.33.1-shadow-cert-log.patch
  freerdp-3.33.1-shadow-output-geometry.patch
  freerdp-3.33.1-idle-capture-on-demand.patch
)
patch_fingerprint="$(
  for name in "$patches[@]"; do
    printf '%s\n' "$name"
    cat "$repo/patches/$name"
  done | shasum -a 256 | awk '{print $1}'
)"
# Patch fingerprints isolate cached FreeRDP source/build trees from concurrent changes.
patch_key="$(printf '%.12s' "$patch_fingerprint")"
freerdp_source="${FREERDP_SOURCE_ROOT:-$build_root/sources/FreeRDP-$version-$patch_key}"
freerdp_build="${FREERDP_BUILD_ROOT:-$build_root/$target_arch/build/freerdp-$patch_key}"
if [[ ! -d "$freerdp_source/.git" ]]; then
  if [[ -n "${FREERDP_SOURCE_ROOT:-}" || -n "${FREERDP_BUILD_ROOT:-}" ]]; then
    echo "Supplied FreeRDP source/build is missing." >&2
    exit 2
  fi
  mkdir -p "$build_root/sources"
  git clone --depth 1 --branch "$version" --recurse-submodules \
    https://github.com/FreeRDP/FreeRDP.git "$freerdp_source"
fi

actual_commit="$(git -C "$freerdp_source" rev-parse HEAD 2>/dev/null || true)"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  echo "FreeRDP source is not the pinned commit $expected_commit: $freerdp_source" >&2
  exit 2
fi

source_digest() {
  {
    git -C "$freerdp_source" diff --binary HEAD
    git -C "$freerdp_source" ls-files --others --exclude-standard |
      while IFS= read -r file; do
        printf '%s\n' "$file"
        shasum -a 256 "$freerdp_source/$file"
      done
  } | shasum -a 256 | awk '{print $1}'
}

mkdir -p "$freerdp_build"
patch_stamp="$freerdp_build/.macremote-patchset"
if [[ -f "$patch_stamp" ]]; then
  expected_state="$expected_commit $freerdp_source $patch_fingerprint $(source_digest)"
  if [[ "$(cat "$patch_stamp")" != "$expected_state" ]]; then
    echo "FreeRDP patchset or cached source changed; use a clean source/build pair." >&2
    exit 2
  fi
else
  patch_index="$work/freerdp-patch-index"
  combined_patch="$work/freerdp-integrated.patch"
  GIT_INDEX_FILE="$patch_index" git -C "$freerdp_source" read-tree HEAD
  for name in "$patches[@]"; do
    patch="$repo/patches/$name"
    if ! GIT_INDEX_FILE="$patch_index" git -C "$freerdp_source" apply --cached --check "$patch"; then
      echo "Pinned FreeRDP patch failed: $name" >&2
      exit 2
    fi
    GIT_INDEX_FILE="$patch_index" git -C "$freerdp_source" apply --cached "$patch"
  done
  GIT_INDEX_FILE="$patch_index" git -C "$freerdp_source" diff --cached --binary HEAD > "$combined_patch"
  if [[ -z "$(git -C "$freerdp_source" status --porcelain)" ]]; then
    git -C "$freerdp_source" apply --check "$combined_patch"
    git -C "$freerdp_source" apply "$combined_patch"
  elif GIT_INDEX_FILE="$patch_index" git -C "$freerdp_source" diff --quiet &&
       [[ -z "$(GIT_INDEX_FILE="$patch_index" git -C "$freerdp_source" ls-files --others --exclude-standard)" ]]; then
    echo "Verified existing FreeRDP source matches the complete pinned patchset."
  else
    echo "FreeRDP checkout has unrecognized edits: $freerdp_source" >&2
    exit 2
  fi
  printf '%s %s %s %s\n' "$expected_commit" "$freerdp_source"     "$patch_fingerprint" "$(source_digest)" > "$patch_stamp"
fi

cmake -S "$freerdp_source" -B "$freerdp_build" -G Ninja \
    -DCMAKE_C_FLAGS="-I$dependency_prefix/include" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DCMAKE_PREFIX_PATH="$dependency_prefix" \
    -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
    -DOPENSSL_ROOT_DIR="$dependency_prefix" \
    -DOPENSSL_SSL_LIBRARY="$dependency_prefix/lib/libssl.3.dylib" \
    -DOPENSSL_CRYPTO_LIBRARY="$dependency_prefix/lib/libcrypto.3.dylib" \
    -DBUILD_SHARED_LIBS=ON -DWITH_SERVER=ON -DWITH_SHADOW=ON \
    -DWITH_CLIENT=OFF -DWITH_CLIENT_CHANNELS=OFF -DWITH_CLIENT_SDL=OFF \
    -DCHANNEL_URBDRC=OFF -DWITH_SAMPLE=OFF -DWITH_X11=OFF \
    -DWITH_APPLE_VIDEOTOOLBOX=ON -DWITH_FFMPEG=OFF \
    -DWITH_SWSCALE=OFF -DWITH_OPUS=ON -DWITH_OPENSSL=ON \
    -DCHANNEL_CLIPRDR_SERVER=ON

cmake --build "$freerdp_build" --parallel "${MACREMOTE_BUILD_JOBS:-4}" \
  --target freerdp-shadow freerdp-shadow-subsystem-impl cliprdr-server
cmake -S "$repo" -B "$native_build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DFREERDP_SOURCE_ROOT="$freerdp_source" \
  -DFREERDP_BUILD_ROOT="$freerdp_build"
cmake --build "$native_build" --parallel "${MACREMOTE_BUILD_JOBS:-4}"
ctest --test-dir "$native_build" --output-on-failure

# Validate app preference persistence without altering the user's defaults.
xcrun swiftc -O -parse-as-library -swift-version 5 \
  "$repo/apps/macos/ListenPortSettings.swift" \
  "$repo/tests/test_port_settings.swift" -o "$work/test-port-settings"
"$work/test-port-settings"

xcrun swiftc -O -parse-as-library -swift-version 5 \
  "$repo/apps/macos/DisplayModels.swift" \
  "$repo/apps/macos/DisplayModeService.swift" \
  "$repo/apps/macos/DisplayModeOperations.swift" \
  "$repo/apps/macos/DisplayConfigurationStore.swift" \
  "$repo/apps/macos/ClientDevicePreferences.swift" \
  "$repo/apps/macos/DisplayOutputSettings.swift" \
  "$repo/tests/test_display_output_settings.swift" \
  -o "$work/test-display-output-settings"
"$work/test-display-output-settings"

xcrun swiftc -O -parse-as-library -swift-version 5 \
  "$repo/apps/macos/ServerController.swift" \
  "$repo/apps/macos/ListenPortSettings.swift" \
  "$repo/apps/macos/ServerRestartPolicy.swift" \
  "$repo/tests/test_server_restart_policy.swift" \
  -o "$work/test-server-restart-policy"
"$work/test-server-restart-policy"

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
  "$repo/apps/macos/MacRemoteDelegate.swift" \
  "$repo/apps/macos/MacRemoteMenu.swift" \
  "$repo/apps/macos/ServerController.swift" \
  "$repo/apps/macos/ListenPortSettings.swift" \
  "$repo/apps/macos/DisplayModels.swift" \
  "$repo/apps/macos/DisplayModeService.swift" \
  "$repo/apps/macos/DisplayModeOperations.swift" \
  "$repo/apps/macos/DisplayConfigurationStore.swift" \
  "$repo/apps/macos/ClientDevicePreferences.swift" \
  "$repo/apps/macos/DisplayOutputSettings.swift" \
  "$repo/apps/macos/EditableResolutionComboBox.swift" \
  "$repo/apps/macos/ServerRestartPolicy.swift" \
  -o "$bundle/Contents/MacOS/MacRemote"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target ${target_arch}-apple-macos14.0 -sdk "$sdk" \
  "$repo/apps/macos/DisplayOverrideTool.swift" \
  -o "$bundle/Contents/MacOS/macremote-display-overrides"
xcrun swiftc -O -parse-as-library -swift-version 5 \
  -target ${target_arch}-apple-macos14.0 -sdk "$sdk" \
  "$repo/apps/macos/DisplayActivationTool.swift" \
  -o "$bundle/Contents/MacOS/macremote-display-activate"

# Recursively bundle FreeRDP and its private dependency graph.
python3 "$repo/tools/bundle-runtime.py" "$bundle" \
  --freerdp-build "$freerdp_build" --dependency-prefix "$dependency_prefix"

for dylib in "$bundle"/Contents/Frameworks/*.dylib "$bundle"/Contents/Frameworks/ossl-modules/*.dylib; do
  codesign --force --options runtime --sign "$sign_identity" "$dylib" >/dev/null
done
codesign --force --options runtime \
  --entitlements "$repo/apps/macos/server-dev.entitlements" \
  --sign "$sign_identity" "$bundle/Contents/MacOS/macremote-server"
codesign --force --options runtime --sign "$sign_identity" \
  "$bundle/Contents/MacOS/macremote-display-overrides"
codesign --force --options runtime --sign "$sign_identity" \
  "$bundle/Contents/MacOS/macremote-display-activate"
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
