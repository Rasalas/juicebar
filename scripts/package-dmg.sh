#!/bin/bash
# Build the public drag-to-Applications disk image from an already notarized app.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${JUICEBAR_VERSION:?Set a release version}"
: "${JUICEBAR_SIGN_IDENTITY:?Set the Developer ID Application identity}"
: "${JUICEBAR_NOTARY_PROFILE:?Set a notarytool Keychain profile}"
dmgbuild="${JUICEBAR_DMGBUILD:-$PWD/.artifacts/dmg-tools/bin/dmgbuild}"
[[ -x "$dmgbuild" ]] || { echo 'Install scripts/dmg-requirements.txt in .artifacts/dmg-tools first.' >&2; exit 1; }
app="$PWD/dist/Juicebar.app"
codesign --verify --deep --strict "$app"
xcrun stapler validate "$app"
release_dir="$PWD/dist/releases/$JUICEBAR_VERSION"
dmg="$release_dir/Juicebar-$JUICEBAR_VERSION-macOS-$(uname -m).dmg"
[[ ! -e "$dmg" ]] || { echo "Disk image already exists: $dmg" >&2; exit 1; }
artwork="$(mktemp -d "${TMPDIR:-/tmp}/juicebar-dmg.XXXXXX")"
trap 'rm -rf "$artwork"' EXIT
swift scripts/make-dmg-background.swift "$artwork"
"$dmgbuild" -s scripts/dmg-settings.py -D "app=$app" -D "background=$artwork/background.png" "Juicebar" "$dmg"
python3 scripts/verify-dmg.py "$dmg"
codesign --force --sign "$JUICEBAR_SIGN_IDENTITY" --timestamp "$dmg"
codesign --verify --strict "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$JUICEBAR_NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
printf 'Prepared signed and notarized installer: %s\n' "$dmg"
