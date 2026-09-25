#!/bin/bash
set -euo pipefail
tool_root="${JUICEBAR_RELEASE_TOOLS:-$HOME/Library/Application Support/Juicebar Release Tools}"
if [[ ! -x "$tool_root/sign_catalog" ]]; then
  echo 'Run scripts/setup-release-tools.sh with JUICEBAR_SIGN_IDENTITY first.' >&2
  exit 1
fi
exec "$tool_root/sign_catalog" "$@"
