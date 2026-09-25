#!/bin/bash
# Keep Keychain clients outside the replaceable build tree, with a stable signed identity.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${JUICEBAR_SIGN_IDENTITY:?Set the Developer ID Application identity}"
[[ "$JUICEBAR_SIGN_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'Developer ID Application identity required.' >&2; exit 1; }
tool_root="${JUICEBAR_RELEASE_TOOLS:-$HOME/Library/Application Support/Juicebar Release Tools}"
mkdir -p "$tool_root"
chmod 700 "$tool_root"
expected_team="${JUICEBAR_SIGN_IDENTITY##*(}"
expected_team="${expected_team%)}"
[[ "$expected_team" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Cannot determine signing team from identity.' >&2; exit 1; }
for tool in generate_appcast generate_keys sign_update; do
  source_tool="$PWD/.build/artifacts/sparkle/Sparkle/bin/$tool"
  test -f "$source_tool"
  source_hash="$(shasum -a 256 "$source_tool" | cut -d ' ' -f 1)"
  saved_hash="$(cat "$tool_root/$tool.source-sha256" 2>/dev/null || true)"
  identifier="app.juicebar.release.$tool"
  requirement="identifier \"$identifier\" and anchor apple generic and certificate leaf[subject.OU] = \"$expected_team\""
  if [[ "$source_hash" != "$saved_hash" ]] || ! codesign --verify --strict --test-requirement "=$requirement" "$tool_root/$tool" 2>/dev/null; then
    cp "$source_tool" "$tool_root/$tool.new"
    codesign --force --sign "$JUICEBAR_SIGN_IDENTITY" --identifier "$identifier" --options runtime --timestamp "$tool_root/$tool.new"
    mv "$tool_root/$tool.new" "$tool_root/$tool"
    printf '%s\n' "$source_hash" > "$tool_root/$tool.source-sha256"
  fi
  codesign --verify --strict --test-requirement "=$requirement" "$tool_root/$tool"
done
catalog_hash="$(shasum -a 256 scripts/sign-catalog.swift | cut -d ' ' -f 1)"
saved_catalog_hash="$(cat "$tool_root/sign_catalog.source-sha256" 2>/dev/null || true)"
requirement="identifier \"app.juicebar.release.sign-catalog\" and anchor apple generic and certificate leaf[subject.OU] = \"$expected_team\""
if [[ "$catalog_hash" != "$saved_catalog_hash" ]] || ! codesign --verify --strict --test-requirement "=$requirement" "$tool_root/sign_catalog" 2>/dev/null; then
  swiftc -O scripts/sign-catalog.swift -o "$tool_root/sign_catalog.new"
  codesign --force --sign "$JUICEBAR_SIGN_IDENTITY" --identifier app.juicebar.release.sign-catalog --options runtime --timestamp "$tool_root/sign_catalog.new"
  mv "$tool_root/sign_catalog.new" "$tool_root/sign_catalog"
  printf '%s\n' "$catalog_hash" > "$tool_root/sign_catalog.source-sha256"
fi
codesign --verify --strict --test-requirement "=$requirement" "$tool_root/sign_catalog"
printf 'Release tools ready: %s\n' "$tool_root"
