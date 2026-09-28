#!/bin/bash
set -euo pipefail
tool_root="${JUICEBAR_RELEASE_TOOLS:-$HOME/Library/Application Support/Juicebar Release Tools}"
if [[ ! -x "$tool_root/sign_catalog" ]]; then
  echo 'Run scripts/setup-release-tools.sh with JUICEBAR_SIGN_IDENTITY first.' >&2
  exit 1
fi
script_directory="$(cd "$(dirname "$0")" && pwd)"
source_hash="$(shasum -a 256 "$script_directory/sign-catalog.swift" | cut -d ' ' -f 1)"
installed_hash="$(cat "$tool_root/sign_catalog.source-sha256" 2>/dev/null || true)"
if [[ "$source_hash" != "$installed_hash" ]]; then
  echo 'Catalog signing tool is outdated. Rebuild it with scripts/setup-release-tools.sh before signing; the old tool may request Keychain dialogs.' >&2
  exit 1
fi
exec "$tool_root/sign_catalog" "$@"
