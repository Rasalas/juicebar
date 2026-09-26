#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product SandboxProbe
binary_dir="$(swift build --show-bin-path)"
probe_root="${JUICEBAR_PROBE_DIRECTORY:-$HOME/Applications/Juicebar Sandbox Probe.app}"
mkdir -p "$probe_root/Contents/MacOS" "$probe_root/Contents/Resources"
cp "$binary_dir/SandboxProbe" "$probe_root/Contents/MacOS/SandboxProbe"
cp -R "$binary_dir/Juicebar_JuicebarCore.bundle" "$probe_root/Contents/Resources/"
# Optional, local feasibility build only. Re-sign the copy to inherit the app's
# sandbox. Never alter the user's installed CLI or download executable updates.
if [[ -n "${JUICEBAR_PROBE_CODEX:-}" ]]; then
    mkdir -p "$probe_root/Contents/Helpers"
    cp -L "$JUICEBAR_PROBE_CODEX" "$probe_root/Contents/Helpers/codex"
    codesign --force --options runtime --sign "${JUICEBAR_SIGN_IDENTITY:--}" \
        --entitlements scripts/sandbox-helper.entitlements "$probe_root/Contents/Helpers/codex"
else
    rm -f "$probe_root/Contents/Helpers/codex"
fi
cat > "$probe_root/Contents/Info.plist" <<'XML'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.juicebar.sandbox-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleName</key><string>Juicebar Sandbox Probe</string>
<key>CFBundleExecutable</key><string>SandboxProbe</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
XML
codesign --force --sign "${JUICEBAR_SIGN_IDENTITY:--}" --entitlements scripts/sandbox.entitlements "$probe_root"
codesign --verify --deep --strict "$probe_root"
printf '%s\n' "$probe_root"
