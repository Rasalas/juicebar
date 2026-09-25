#!/bin/bash
# Read-only package checks. Run on the second Mac after installing the official ZIP.
set -euo pipefail
app="${1:-/Applications/Juicebar.app}"
test -d "$app"
printf 'System: '
sw_vers -productVersion
printf 'Architecture: '
uname -m
printf 'App version: '
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist"
printf 'App build: '
/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose=2 "$app"
xcrun stapler validate "$app"
printf 'Package verification passed. Launch from Applications, connect providers and test notifications in the GUI.\n'
