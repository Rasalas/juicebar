#!/bin/bash
# Prepare a signed, notarized archive and Sparkle feed. Does not publish anything.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${JUICEBAR_VERSION:?Set a release version, e.g. 0.1.0}"
: "${JUICEBAR_BUILD:?Set a strictly increasing integer build number}"
: "${JUICEBAR_SIGN_IDENTITY:?Set a Developer ID Application identity}"
: "${JUICEBAR_NOTARY_PROFILE:?Set a notarytool Keychain profile name}"
[[ "$JUICEBAR_SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Developer ID Application identity required.' >&2; exit 1; }
export JUICEBAR_DISTRIBUTION=direct
swift package resolve
sparkle_bin="$PWD/.build/artifacts/sparkle/Sparkle/bin"
export JUICEBAR_UPDATE_PUBLIC_KEY
JUICEBAR_UPDATE_PUBLIC_KEY="$("$sparkle_bin/generate_keys" --account juicebar -p)"
bash scripts/build-app.sh
release_dir="dist/releases/$JUICEBAR_VERSION"
if [[ -e "$release_dir" ]]; then
  echo "Release directory already exists: $release_dir. Review it before preparing another archive." >&2
  exit 1
fi
mkdir -p "$release_dir"
submission="$release_dir/notary-submission.zip"
ditto -c -k --sequesterRsrc --keepParent dist/Juicebar.app "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$JUICEBAR_NOTARY_PROFILE" --wait
xcrun stapler staple dist/Juicebar.app
xcrun stapler validate dist/Juicebar.app
spctl --assess --type execute --verbose dist/Juicebar.app
archive="$release_dir/Juicebar-$JUICEBAR_VERSION-macOS-$(uname -m).zip"
ditto -c -k --sequesterRsrc --keepParent dist/Juicebar.app "$archive"
rm "$submission"
"$sparkle_bin/generate_appcast" --account juicebar --download-url-prefix "https://github.com/Rasalas/juicebar/releases/download/v$JUICEBAR_VERSION/" "$release_dir"
(cd "$release_dir" && shasum -a 256 "$(basename "$archive")") > "$release_dir/SHA256SUMS.txt"
printf 'Prepared %s. Test installation and an old-to-new update before publishing.\n' "$release_dir"
