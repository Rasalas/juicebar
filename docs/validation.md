# Validation status · 25 September 2026

## Reproducible checks

```sh
swift test
python3 Tests/ssh_usage_test.py
swift run Juicebar --verify-tray-layout
swift run Juicebar --verify-activity-persistence
swift run Juicebar --render-previews
bash scripts/build-app.sh
codesign --verify --deep --strict dist/Juicebar.app
JUICEBAR_DISTRIBUTION=direct swift build
```

All 42 Swift tests and all three Python collector tests pass locally. The Swift suite covers provider normalization, additional and hidden limits, plan labels, warning epochs, expiry, pacing, settings migration, SQLite persistence, process deadlines, activity deduplication, partial log lines, historical Claude aggregates, token accounting, pricing and confirmed alpha aliases. Python tests check that the SSH collector returns usage metadata and excludes conversation content.

The tray regression uses SwiftUI's intrinsic size proposal, verifies that ordinary accounts fit, and caps the viewport only when available height is exhausted. The persistence check opens a fresh store over an isolated database and verifies cost/history data before any import. Render previews use synthetic data; they are not screenshots of real accounts.

## Integrations checked locally

Codex quota and reset data, Claude limits, OpenCode Go limits, local OpenCode history and SSH activity collection were exercised on a development Mac. Existing log files and remote files were not modified. API organization-cost integrations and OpenRouter have fixture coverage but have not been exercised with real admin/management keys.

Source builds were tested on Apple Silicon. The full supported macOS-version range, Intel hardware, login launch and prolonged resource behavior have not been tested. Short idle samples are not evidence of leak-free operation.

## macOS permissions

Launching provider processes with a sanitized working directory fixes a reproduced inherited `PWD` mismatch. Launching an app bundle directly from removable storage can still cause a macOS file-access prompt. No full-disk-access permission is required or changed by the app.

Notification delivery was observed in Notification Center. macOS can suppress the banner and sound during display sharing or Focus even when app-specific notifications are enabled. Juicebar shows the available notification settings but does not override global preferences.

## Distribution checks still outstanding

Installing on another Mac and broader supported-version coverage remain outstanding. Signing, notarization and the installed update path have now been exercised as described below. App Store sandbox compatibility/review and Windows/Linux ports are not complete.

The source and direct-download app bundles both build and pass deep signature verification with ad-hoc signing. The direct bundle includes Sparkle and its licenses; a test archive produces an Ed25519-signed appcast. This is a packaging smoke test, not a notarization or installed-update test.

The first public [macOS CI run](https://github.com/Rasalas/juicebar/actions/runs/36184823187) also passed on the macos-15 runner, including source packaging and direct-updater compilation. This does not replace installation testing across supported macOS versions.

## First direct release

Version 0.1.0 build 2 is Developer ID signed and accepted by Apple's notary service. The ticket was stapled, validated and accepted by `spctl`. A notarized build 1 with an explicit candidate feed found the public prerelease through Sparkle, downloaded it, offered installation and relaunched as build 2. The installed build uses the normal stable feed. Account, settings, SSH-source and path hashes were unchanged; usage-day and response counts were retained. Codex, Claude and OpenCode Go returned fresh values after relaunch.

Sparkle's signature tool accepted the original archive and rejected a modified copy. Feed version, archive length and checksum were checked. No signing key or account secret is included in the repository or release assets. Cancellation, forced network failure and installation on another Mac remain additional coverage, not claims of this test.

## Follow-up release checks

Version 0.1.1 adds English/German UI, guided CLI setup and the signed model catalog. Tests cover signature tampering, unknown schemas, oversized files, invalid prices/dates, alias collisions, downgrade rejection and cached/bundled fallback. Translation tests preserve interpolation arguments, including braces in provider-supplied values.

The separate sandbox probe and its measured limits are documented in [sandbox feasibility](sandbox-feasibility.md). It does not modify the shipping app's container or credentials.

The project website was checked at 1280 px and 390 px widths with no horizontal overflow. Screenshots show synthetic app data. Store screenshot drafts are rendered at 2560 × 1600 in English and German; they are not evidence of a completed store build.

### Second Mac installation

A configured MacBook SSH alias was found but connection to port 22 timed out. No remote changes were made. Fresh-Mac installation remains unverified.

When the MacBook is available, install the public release from GitHub, then run `bash scripts/check-installed-app.sh /Applications/Juicebar.app`. Also verify first launch without bypassing Gatekeeper, fresh Codex/Claude/OpenCode connections, notification permission and sound, sleep/wake, and one Sparkle update. A signature check on the development Mac is not a substitute for this test.

### Resource observation

The installed 0.1.0 build was sampled every 30 seconds for 30 minutes, 61 samples, while development continued. The main process used 18.0–189.9 MiB resident memory and ended at 127.7 MiB. Sampled CPU ranged from 0 to 0.6%. There was no sustained upward resident-memory trend across the interval. This is a limited observation, not proof of leak freedom; it excludes short spikes between samples, compressed memory and separate provider/SSH child processes. The 0.1.1 build still needs its own longer observation.

### Public 0.1.1 update

The public stable feed offered 0.1.1 to installed 0.1.0. Remind Me Later closed the dialog, and another manual check offered the update again. The installed app then relaunched as 0.1.1, build 3. Developer ID, notarization ticket and Gatekeeper assessment passed. All four previously stored configuration groups matched their pre-update hashes; both usage caches and 361 quota observations were still present. Codex, Claude and OpenCode Go returned current quotas after launch.

The public catalog and appcast were byte-for-byte identical to the locally validated release files. GitHub macOS CI passed for release commit `e4382d7`; the Pages deployment succeeded. A forced failed-download test is still outstanding.


## Version 0.1.2 installer and website

The public Mac download is a Developer ID signed and notarized DMG, with an Applications shortcut and an installation background. Both the app and final disk image passed Apple notarization, ticket stapling and Gatekeeper assessment. The installed copy passes deep, strict signature verification after copying from the read-only image. An initial, unpublished candidate set FinderInfo on the signed bundle to hide its extension; this was removed, and the release pipeline now performs a mount-and-copy verification before signing the DMG.

The downloaded public DMG was byte-identical to the tested local artifact and passed ticket/Gatekeeper checks. The Sparkle ZIP remains separate; its Ed25519 signature verifies against the embedded public key and fails after changing one archive byte. Both GitHub macOS runs for release commit `d12dd96` passed. All 47 local Swift tests passed; the normal tray remains 677 pt tall and respects the 500 pt constrained-height case.

The website uses the actual `MenuLimitImage` renderer for its quota symbols and the new segmented-droplet logo. Direct buttons link to the DMG. Browser checks covered 1280, 390 and 320 px widths without horizontal overflow, plus Apple Silicon hints, Intel hints, Safari without CPU hints, Windows, Linux, iPad, Android, unknown platform and denied CPU hints. Unsupported systems receive an availability message and an explicit alternative Mac link. Safari's generic “Intel Mac” user-agent is not treated as CPU evidence.

A fresh second-Mac installation test remains outstanding. The measured App Store sandbox blockers are unchanged; submission is authorized but no working store build has been submitted.

After publication, the installed 0.1.1 app found 0.1.2 through the stable Sparkle feed, downloaded it, installed it and relaunched as build 4. Deep signature verification passed. Hashes for all four account/settings/SSH/path preference groups remained identical; quota observations increased from 408 to 411. The public Pages deployment succeeded and its primary buttons point directly to the verified DMG. The preview browser reported macOS with `architecture: arm` and displayed the Mac download correctly.

## Store feasibility and Claude access, 26 September

The isolated sandbox probe now supports a bundled Codex helper, official browser login into its own container, quota/reset-offer reads, restart without folder grants and an explicit token-refresh request. A separate Claude Code statusLine experiment exports real five-hour and weekly percentages with reset times. The sandbox consumer reads the selected export folder and retains the original receipt time after restart; access without a grant is denied. See [full results and limits](sandbox-feasibility.md). This is not a submitted store build.

All 50 Swift tests and three Python collector tests passed. Tray layout remains 677 pt normally and 500 pt when constrained. Activity persistence passed. Additional tests cover bounded credential-free exports, malformed input, expired windows and an explicit process working directory containing spaces.

The 0.1.3 build removes direct extraction of Claude OAuth credentials and the private reset-offer request. Its live diagnostic returned Codex quotas/reset inventory, Claude five-hour/weekly/Fable limits, and all three OpenCode Go limits. Claude reset inventory correctly remains unknown. The app and DMG passed Developer ID signing, notarization, ticket validation and Gatekeeper checks. The downloaded public DMG matched the locally validated artifact. Sparkle verified the updater archive, and a modified archive failed Ed25519 verification. Both GitHub macOS runs for release commit `7a6aef6` passed.

Installed 0.1.2 updated through Sparkle to 0.1.3 build 5 while the candidate was a prerelease. A temporary per-user feed override selected that candidate and was removed immediately after installation; the app now uses the normal stable feed. All four account/settings/SSH/path preference groups kept their hashes. Usage-import caches updated normally, and quota observations increased from 1,347 to 1,356. The installed app retained valid signing/notarization and returned current Codex, Claude/Fable and OpenCode Go limits. The same tested artifacts were then promoted to stable.


## Version 0.1.4 screenshots and update, 26 September

The screenshot command renders the current native views offscreen in English and German with synthetic data. It updates the project website, optional German portfolio checkout and HTML image dimensions. The portfolio tests passed at 390 and 1280 px, with all three images keeping their natural aspect ratios and no horizontal overflow. All 50 Swift tests, three SSH collector tests, tray layout and activity persistence checks passed. Both macOS CI runs for release commit `799041f` passed.

The app and DMG were Developer ID signed, notarized and stapled. The public DMG and feed matched the tested local files. Copying the app out of the public DMG preserved its signature, notarization ticket and Gatekeeper acceptance. The Sparkle archive passed Ed25519 verification; changing one byte made verification fail.

Installed 0.1.3 offered the 0.1.4 prerelease; dismissing the offer and checking again offered it again. Sparkle downloaded, installed and relaunched 0.1.4 build 6. All four account/settings/SSH/path configuration hashes remained unchanged, both usage caches were retained, and quota observations increased from 1,511 to 1,517. Codex, Claude/Fable and OpenCode Go returned fresh limits. The temporary candidate-feed override was removed, then the same tested release assets were promoted to stable. A forced failed-download test and installation on a second Mac remain outstanding.


## Juicebars 0.1.5 branding, 26 September

The app now uses three blue, terracotta and lavender bars, generated from one geometry for SVG, in-app PNG and ICNS. English and German native screenshots were refreshed, along with the project website and portfolio. Website checks covered desktop and mobile layouts; the portfolio typecheck, build and four browser tests passed. All 50 Swift tests, three collector tests, tray layout and activity persistence checks passed. Both macOS CI runs for `4805ad7` passed.

The app and DMG passed Developer ID signing, notarization, stapling and Gatekeeper assessment. The public DMG matched the local artifact byte for byte. The updater archive verified against the bundled Ed25519 public key; a modified archive failed verification.

Installed 0.1.4 updated through Sparkle to the 0.1.5 prerelease, build 7. The installed app's name and icon match the new assets, and signature/notarization checks passed. Account, settings, SSH and path configuration hashes remained unchanged; both usage caches were retained and observations increased from 1,550 to 1,556. The temporary candidate feed override was removed before promoting the tested artifacts to stable. Existing bundle, executable, storage and URL identifiers remain unchanged for compatibility.
