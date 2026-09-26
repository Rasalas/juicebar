#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product StatuslineExport
probe_binary_dir="$(swift build --show-bin-path)"
python3 - "$probe_binary_dir/StatuslineExport" <<'PY'
import json
import pathlib
import shlex
import shutil
import sys

root = pathlib.Path.home() / 'Library/Application Support/Juicebar Sandbox Tools'
workspace = root / 'claude-workspace'
settings = workspace / '.claude/settings.json'
settings.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(sys.argv[1], root / 'StatuslineExport')
output = pathlib.Path.home() / '.claude/juicebar-probe/status.json'
command = shlex.join([str(root / 'StatuslineExport'), str(output)])
settings.write_text(json.dumps({'statusLine': {'type': 'command', 'command': command}}, indent=2) + '\n')
print('Prepared isolated Claude test workspace:', workspace)
print('Export destination:', output)
print('Global Claude settings were not changed.')
PY
