#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
distribution="${JUICEBAR_DISTRIBUTION:-source}"
if [[ "$distribution" != source && "$distribution" != direct ]]; then
  echo 'Supported builds: source or direct. The App Store target is not ready.' >&2
  exit 1
fi
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app="dist/Juicebar.app"
# Do not retain a framework, signature or resource from a different build flavor.
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/Juicebar" "$app/Contents/MacOS/Juicebar"
cp -R "$binary_dir/Juicebar_Juicebar.bundle" "$app/Contents/Resources/"
cp -R "$binary_dir/Juicebar_JuicebarCore.bundle" "$app/Contents/Resources/"
cp assets/Info.plist "$app/Contents/Info.plist"
swift scripts/make-icon.swift "$app/Contents/Resources"
mkdir -p "$app/Contents/Resources/Licenses"
cp LICENSE THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Licenses/"
cp assets/providers/LICENSE-T3 "$app/Contents/Resources/Licenses/"
if [[ "$distribution" == direct ]]; then
  sparkle_dir=".build/artifacts/sparkle/Sparkle"
  mkdir -p "$app/Contents/Frameworks"
  ditto "$sparkle_dir/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
  cp "$sparkle_dir/LICENSE" "$app/Contents/Resources/Licenses/LICENSE-Sparkle"
fi
python3 - "$app/Contents/Info.plist" <<'PY'
import base64, os, plistlib, re, sys
from urllib.parse import urlparse
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
for variable, field, pattern in [('JUICEBAR_VERSION', 'CFBundleShortVersionString', r'\d+\.\d+\.\d+'), ('JUICEBAR_BUILD', 'CFBundleVersion', r'[1-9]\d*')]:
    value = os.environ.get(variable)
    if value:
        if not re.fullmatch(pattern, value):
            raise SystemExit(f'Invalid {variable}')
        info[field] = value
if os.environ.get('JUICEBAR_DISTRIBUTION') == 'direct':
    key = os.environ.get('JUICEBAR_UPDATE_PUBLIC_KEY', '')
    try:
        valid_key = len(base64.b64decode(key, validate=True)) == 32
    except ValueError:
        valid_key = False
    if not valid_key:
        raise SystemExit('A direct build needs JUICEBAR_UPDATE_PUBLIC_KEY (Sparkle Ed25519 public key).')
    feed = os.environ.get('JUICEBAR_UPDATE_FEED_URL', 'https://github.com/Rasalas/juicebar/releases/latest/download/appcast.xml')
    parsed = urlparse(feed)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password:
        raise SystemExit('The update feed must be an HTTPS URL without credentials.')
    info.update(SUFeedURL=feed,
                SUPublicEDKey=key, SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
                SUEnableSystemProfiling=False, SUScheduledCheckInterval=86400)
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
identity="${JUICEBAR_SIGN_IDENTITY:--}"
sign_args=(--force --sign "$identity")
if [[ "$identity" != - ]]; then
  if [[ "$identity" != 'Developer ID Application:'* ]]; then
    echo 'Public direct builds require a Developer ID Application identity.' >&2
    exit 1
  fi
  sign_args+=(--options runtime --timestamp)
fi
if [[ "$distribution" == direct ]]; then
  framework="$app/Contents/Frameworks/Sparkle.framework"
  for component in "$framework/Versions/B/XPCServices/Downloader.xpc" "$framework/Versions/B/XPCServices/Installer.xpc" "$framework/Versions/B/Autoupdate" "$framework/Versions/B/Updater.app" "$framework"; do
    codesign "${sign_args[@]}" "$component"
  done
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$PWD/$app"
