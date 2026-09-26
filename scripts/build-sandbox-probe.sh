#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product SandboxProbe
binary_dir="$(swift build --show-bin-path)"
probe_root="${JUICEBAR_PROBE_DIRECTORY:-$HOME/Applications/Juicebar Sandbox Probe.app}"
probe_id="${JUICEBAR_PROBE_BUNDLE_ID:-app.juicebar.sandbox-probe}"
if [[ ! "$probe_id" =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf 'Invalid probe bundle identifier\n' >&2
    exit 1
fi
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
# Offline launch experiment only. Preserve Anthropic's exact binary and signature;
# do not re-sign it or change its entitlements to make the experiment pass.
if [[ -n "${JUICEBAR_PROBE_CLAUDE:-}" ]]; then
    mkdir -p "$probe_root/Contents/Helpers"
    cp -L "$JUICEBAR_PROBE_CLAUDE" "$probe_root/Contents/Helpers/claude"
    cmp "$JUICEBAR_PROBE_CLAUDE" "$probe_root/Contents/Helpers/claude"
    codesign --verify --strict "$probe_root/Contents/Helpers/claude"
else
    rm -f "$probe_root/Contents/Helpers/claude"
fi
cat > "$probe_root/Contents/Info.plist" <<XML
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$probe_id</string>
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
