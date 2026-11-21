#!/bin/zsh
# Build a signed GitHub Release asset locally. Never publish or replace the installed app.
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/.." && pwd)"
signer='Ahang Open Source Release Signing'
arch="$(uname -m)"
[[ "$arch" == 'arm64' || "$arch" == 'x86_64' ]] || { echo "Unsupported architecture: $arch" >&2; exit 2; }
security find-identity -v -p codesigning | grep -Fq "\"$signer\"" || {
  echo "Required GitHub Release certificate is missing: $signer" >&2
  exit 2
}
log="$(mktemp /tmp/macremote-public-release.XXXXXXXX)"
trap 'rm -f -- "$log"' EXIT
MACREMOTE_SIGN_IDENTITY="$signer" "$repo/tools/build-dev-app.sh" | tee "$log"
app="$(sed -n 's/^MACREMOTE_APP=//p' "$log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo 'Release app was not created' >&2; exit 2; }
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dmg="$repo/.build/output/MacRemote-macos-$arch-selfsigned-$stamp.dmg"
python3 "$repo/tools/package-dmg.py" --app "$app" --arch "$arch"   --release-identity "$signer" --out "$dmg"
printf 'GITHUB_RELEASE_ASSET=%s
' "$dmg"
