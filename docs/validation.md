# Validation status · 25 September 2026

## Juicebars 0.1.17 release, 23 October

A negative weekly allowance was clamped to zero before conversion into the five-hour work-plan target. Once the weekly reserve was exceeded, that made the short marker follow the actual remaining balance and falsely appear on target. The conversion now retains the signed difference and clamps only the final percentage. The reported 50% short/21% weekly state reaches a 100% short target, while smaller overruns preserve the previous short-window allowance.

The regression first failed with `50.0 is not equal to 100.0` and then passed after the correction. All 192 Swift tests completed with seven optional tests skipped and no failures; all 13 Python collector tests passed. Tray layout, constrained height, forced scrollbars and persistence passed. Native fixtures were inspected in remaining/dark and used/light modes, and English/German screenshots were refreshed. Both macOS checks passed for tagged source `d06efb3`; PR #23 merged as `a82ab90`.

Version 0.1.17, build 21, passed Developer ID signing, Apple notarization, stapling, Gatekeeper assessment and DMG copy verification. Both checksums passed, all four downloaded draft assets matched their originals, and the Sparkle signature verified while a modified byte was rejected. Layout and persistence also passed in the signed bundle.

The installed 0.1.16 exercised a temporary candidate feed. A missing archive produced the expected error, and postponing the valid offer allowed it to appear again. Sparkle then installed build 21. The installed app passed signature and notarization checks. All four configuration groups stayed byte-identical, all 2,765 meaningful observations survived, and the cached activity report retained 212 day entries. The real account's five-hour work target now reports 100% remaining while the week retains its 42% reserve. No reset credit was redeemed. The feed override was removed, the server stopped and the app relaunched against the regular stable feed.

The deliberate error dialog interrupted the user. AGENTS.md now requires isolated failure tests; the release procedure limits their repetition to updater or packaging changes. The installed user app is reserved for successful updates from valid candidates.

The public stable feed serves build 21; the public DMG matches the tested artifact. Website download links target 0.1.17.

## Juicebars 0.1.16 release, 22 October

Work-plan information now stays in the quota popover, with only the green diamond on the bar. All markers share the exact percentage centerline, including the endpoints. The overview reset count opens Reset credits. Available Codex credits have a “Reset einlösen” action with native confirmation, fresh account-identity checks and a persisted idempotency key for interrupted attempts. Regular polling never redeems a credit.

The Swift suite completed 190 tests with seven optional benchmarks skipped and no failures. All 13 Python collector tests passed, as did English/German tray layout, constrained-height and forced-scrollbar cases, and activity persistence. Thirteen new tests cover the redemption protocol and app state using synthetic CLI responses and injected services, including retries across restarts, changed identities, expired credits, concurrent attempts and missing follow-up reads. No reset was redeemed on a real account. Native previews confirm the concise markers and redemption layout; English/German screenshots were refreshed. Both macOS checks passed for source `fe4cdd3`; PR #21 merged as `a41b57d`.

Version 0.1.16, build 20, was packaged from clean tagged source `fe4cdd3`. The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. Copying the app out of the DMG preserved its signature. Both checksum entries passed, and all four downloaded draft assets matched their local originals. The Sparkle archive signature verified against the bundled public key; a changed byte was rejected. Layout and activity persistence also passed in the signed bundle.

The exact build 20 archive was installed through Sparkle using a temporary loopback feed. The installed app passed signature, notarization and Gatekeeper checks. All four account/settings/SSH/path configuration groups remained byte-identical, all 2,569 meaningful observations survived, and the two usage caches retained their 210 and 22 day entries. No real-account redemption request was created. The feed override was removed and the app relaunched against the regular stable feed.

The published stable feed serves build 20, and the public DMG matches the tested local artifact. Website download links target the public 0.1.16 assets.

## Juicebars 0.1.15 release, 22 October

The account editor adds an optional work schedule, disabled by default, with weekdays and working hours. A green diamond on the existing quota bars marks the daily target or the reserve for upcoming workdays. Compact labels show today's remaining allocation, free-day buffer and estimated extra five-hour windows outside working hours. The conversion uses the account's measured consumption ratio and reported reset. Missing measurements do not produce a claimed five-hour capacity. Both overview and tray have one shared legend at the bottom.

The local Swift suite completed 177 tests with seven optional benchmarks skipped and no failures. All 13 Python collector tests passed, as did English/German tray layout, forced system scrollbars and activity persistence. Native light/dark previews cover workdays, free days with a buffer and fully reserved weeks in both display modes. English/German screenshots were refreshed; website images loaded without overflow at 1280 and 390 CSS pixels. The CI compiler initially timed out on the quota bar's large SwiftUI expression; extracting its title, track and captions resolved it. PR #19 passed macOS CI and merged as `1e159a4`.

Version 0.1.15, build 17, was packaged from clean tagged source `1498161`. The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. The app's signature survived mounting the DMG and copying the app out. Both checksum entries passed. All four files downloaded from the GitHub draft matched their local originals. The Sparkle archive signature verified against the bundled public key; a changed byte was rejected. Repeated signing completed unattended in 0.19 and 0.07 seconds. Native layout and activity persistence also passed in the signed bundle.

Installed 0.1.14 tested the exact signed archive through a temporary loopback feed. A missing ZIP produced a download error and retained 0.1.14. “Remind Me Later” dismissed the valid offer, which appeared again on manual checking. Sparkle downloaded, installed and relaunched 0.1.15, build 17. The installed app passed signature, notarization and Gatekeeper checks. Immediately after installation, all four stored account/settings/SSH/path configuration groups were byte-identical. All 2,542 meaningful observations from the online SQLite backup survived; normal retention removed 77 unchanged older polls. Both usage caches remained, with 210 and 22 activity-day entries. The test feed override was removed and the app restarted with its regular stable feed.

Main macOS CI passed for `1e159a4`. The published stable feed serves build 17, and the public DMG matches the tested local artifact. Download links target the public 0.1.15 assets.

## Juicebars 0.1.14 release, 21 October

Exhausted menu bar quotas keep a faint provider-colored track in their original slot. The red exhaustion outline and the extra warning badge are removed; approaching-limit forecasts retain their yellow outlines. Native light and dark previews were checked, and English and German screenshots were refreshed.

The local Swift suite completed 157 tests with zero failures and seven optional benchmarks skipped. All 13 Python collector tests passed, as did English and German tray layout checks, the constrained-height and always-visible-scrollbar cases, and activity persistence. The signed release bundle also passed layout and persistence checks. The website loaded all images without horizontal overflow at 1280 and 390 CSS pixels. Offscreen SwiftUI still does not expose accessibility descendants on this Mac; live VoiceOver remains unverified.

PR #17 merged as `771513e` after its macOS check passed. Version 0.1.14, build 16, was packaged from the clean tagged source. The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. The app passed signature verification both inside the mounted DMG and after copying it out. Both checksums passed, and all four files downloaded from the GitHub draft matched the local originals. The Sparkle ZIP signature verified against the bundled public key; a modified byte was rejected. Repeated archive signing completed unattended in 0.08 and 0.07 seconds.

Before publication, installed 0.1.13 used a temporary loopback feed to test this exact signed archive. A missing ZIP produced a download error and retained 0.1.13. “Remind Me Later” dismissed the valid offer; a subsequent manual check offered it again. Sparkle downloaded, installed and relaunched 0.1.14, build 16. The installed app passed signature, notarization and Gatekeeper checks. The four stored configuration groups remained byte-identical, all 2,311 meaningful observations from the online SQLite backup survived, and both usage caches retained their 208 and 22 day entries. The test feed override was removed and the app restarted against the normal stable feed.

The published stable feed serves build 16, and the public DMG matches the tested local release. Download links now target the public 0.1.14 assets.

## Juicebars 0.1.13 release, 20 October

The weekly target uses the same neutral diamond symbol as the even-usage marker, clipped to one half with rounded cut corners. Both markers share their vertical center; the lower corner of the half diamond anchors its horizontal target. The extra target line under the five-hour bar is removed. The legend now says “Gleichmäßiger Verbrauch”, and quota details show the estimated usable weekly balance and explain how full windows are estimated from provider measurements, without asserting a model-mix conversion.

Local validation passed 159 Swift tests, with seven opt-in benchmarks skipped, and 13 Python collector tests. Tray checks passed in both languages, at the constrained height and with always-visible system scrollbars; activity persistence and source packaging passed. English and German native screenshots were refreshed. Marker fixtures cover both sides of the even-usage marker, both quota display modes, both appearances and exhausted quota at the track edge. A pixel comparison confirms the cut-corner rounding affects both marker directions. The website loaded all images without horizontal overflow at 1280 and 390 CSS pixels. Offscreen SwiftUI still does not expose accessibility descendants on this Mac; live VoiceOver remains unverified.

PR #15 merged as `680617b` after both macOS checks passed; main CI also passed. Version 0.1.13, build 15, was packaged from the clean tagged source. The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. Both checksums passed, and all four assets downloaded from the GitHub draft matched their local originals. The Sparkle ZIP signature verified against the bundled key; a modified byte was rejected. Repeated signing completed unattended in 0.18 and 0.13 seconds. Layout and persistence checks also passed in the signed bundle.

Before publication, installed 0.1.12 used a temporary loopback feed to test this exact signed archive. A missing ZIP produced a download error and retained 0.1.12. “Remind Me Later” dismissed the valid offer; a subsequent manual check offered it again. Sparkle downloaded, installed and relaunched 0.1.13, build 15. The installed app passed signature, notarization and Gatekeeper checks. All four stored account/settings/SSH/path preference groups remained byte-identical, all 3,533 meaningful observations in the baseline survived, and both usage caches retained their 206 and 22 day entries. The feed override was removed and the app restarted against the normal feed.

The published stable feed serves build 15, and the public DMG matches the tested local release. Download links now target the public 0.1.13 assets.

## Juicebars 0.1.12 release, 20 October

Version 0.1.12, build 14, includes the history retention fix in PR #12, streaming activity aggregation in #13 and consistent time labels in #10. Main CI passed for the combined source commit `cb0b341`. Local validation passed 170 Swift tests with seven opt-in benchmarks skipped, 13 Python collector tests, tray checks in English and German, the constrained-height and always-visible-scrollbar cases, and activity persistence in the signed bundle.

The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. Both checksum entries passed. All four files downloaded from the GitHub draft matched the local originals. The Sparkle ZIP signature verified against the bundled public key; changing one byte caused rejection. Repeated archive signing completed without interaction in 0.13 and 0.08 seconds. The published stable feed serves build 14.

Before publication, the installed signed 0.1.10 was offered this exact candidate through a temporary loopback feed. A missing ZIP produced a download error and left 0.1.10 installed. Dismissing the offer with Remind Me Later allowed it to be offered again. Sparkle then downloaded, installed and relaunched 0.1.12, build 14. Its installed signature, notarization ticket and Gatekeeper checks passed. The test feed override was removed, and the app was restarted against its normal feed.

An online SQLite backup taken before the update held 12,000 quota observations. While 0.1.10 remained open during preparation, its existing global row limit removed the oldest six rows; these were restored from the backup after the update. Every meaningful observation in the backup is present after the update: quota changes, period boundaries and all observations younger than a day. Replaying the new retention code against a separate untouched copy of that backup also preserved all such observations across four accounts. Four account/settings/SSH/path preference groups remained byte-for-byte identical. Both imported usage caches remain present with the same 206 activity-day and 22 local-usage-day entries. Repeated unchanged older quota observations were thinned as intended. Codex and both Claude accounts returned fresh results; OpenCode Go still reports the pre-existing expired login.

The suspected import slowdown did not reproduce in optimized builds. Alternating runs of `testOpenCodeImportPropagatesRowLimitWarning` took 1.16/1.07 seconds before the three merges and 1.03/0.99 seconds after them. The debug suite completed in about ten seconds after host load fell; earlier 253-second timings under heavy host load are not evidence of a release regression.

Version 0.1.11 was withdrawn from the stable feed before this release because its 1,200-row per-account quota history was too short for weekly-target learning. Direct updates from 0.1.10 to 0.1.12 bypass that cap. English and German native screenshots were refreshed. The website loaded all images without horizontal overflow at 1280 and 390 CSS pixels, and both download buttons target the public 0.1.12 DMG. Live VoiceOver and installation on a second Mac remain unverified.

## Juicebars 0.1.11 release, 20 October

Version 0.1.11, build 13, contains PRs [#5](https://github.com/Rasalas/juicebar/pull/5) to [#9](https://github.com/Rasalas/juicebar/pull/9): reliability fixes, lower idle cost, incremental activity imports, the UI/UX review fixes and the weekly target. Each merge into a branch with conflicts was resolved and tested locally before merging; the final merged tree ran 151 Swift tests (6 benchmarks skipped) and passed tray layout in both languages. Main CI passed for every merge.

The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. Both checksum entries passed, all four downloaded draft assets matched the local originals, and the public ZIP matched after publishing. The Sparkle archive verified against the public key, while changing one byte caused rejection. Tray layout and activity persistence checks passed in the signed bundle. The stable feed initially served build 13; this release was later withdrawn and superseded by 0.1.12.

No old-to-new Sparkle update or failed-download test was run before publishing; the installed 0.1.10 is updated through the public feed instead. English and German screenshots were refreshed with a pinned region per language. Live VoiceOver and installation on a second Mac remain unverified.

## Juicebars 0.1.10 release, 15 October

Version 0.1.10, build 12, includes the review fixes and CPU improvements documented below. [PR #4](https://github.com/Rasalas/juicebar/pull/4) was merged after both macOS checks passed. Main and tag CI also passed: 106 regular Swift tests, nine Python collector tests, tray layout in both scrollbar modes, persistence, source packaging and direct-updater compilation. The new recovery test initially failed on the English CI host because it expected a German word; its assertion now uses the active translation.

The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. All four assets downloaded from the public candidate matched the local originals. Both checksum entries passed; copying the app out of the public DMG preserved its signature and notarization. The Sparkle archive verified against the public key, while changing one byte caused rejection. Repeated signing completed without Keychain prompts. Tray and persistence checks also passed directly in the signed release bundle.

Installed 0.1.9 exercised a localhost feed with a missing ZIP: Sparkle displayed a download error and retained the old version. The real 0.1.10 offer could be dismissed and offered again. Sparkle then downloaded, installed and relaunched build 12. All four account/settings/SSH/path configuration hashes stayed identical, both usage caches remained present, and the bounded quota history retained 12,000 observations. Codex, Claude/Fable and OpenCode Go returned fresh values. Quota details opened on click, and their reset/pace descriptions appeared in the native accessibility tree. The temporary feed override was removed before promoting the same tested artifacts to stable; the stable feed serves build 12.

English and German screenshots were refreshed. The website was checked at 1280 and 390 px without missing images or horizontal overflow. Live VoiceOver and installation on a second Mac remain unverified. Component benchmarks below do not establish a whole-app CPU percentage for the installed release.

## Review fixes and CPU profiling, 15 October

All six review findings are addressed: unreadable preferences cannot be silently replaced by defaults; quota periods tolerate fractional reset jitter without repeating warnings; partial OpenCode imports retain their warnings; provider work is bounded and independent per account; quota details can be opened by click or keyboard and include reset/pace accessibility values; removed or edited accounts reject late results. The 30/90-day selection now controls the calendar and active-day counts consistently. Recovery preserves original preference blobs before resetting affected settings.

The installed 0.1.9 process reproduced CPU spikes up to 125.1%. Over a 359.4-second observation it used 33.74 CPU-seconds. Its local cache contained 3,983 files, 79 MiB and 552,929 normalized events. A separate seven-minute stack sample identified repeated plist decoding, OpenCode SQLite scans, ISO date parsing during SSH import and activity aggregation. Provider control connections mostly waited in `poll`. These samples were taken while the Mac was also running other builds.

Release benchmarks compare the original importer code at `ff74fbb` with these changes. CPU time comes from `getrusage`; wall time varied with host load. Identical synthetic inputs produced matching counts, dates and costs.

- Aggregating 100,000 events: 0.49–0.52 CPU-seconds before, 0.046–0.065 after.
- Aggregating 1,152,000 events: 5.16–5.45 CPU-seconds before, 1.41–1.56 after.
- Repeating a 20,000-row OpenCode import: 0.78–1.07 CPU-seconds before, 0.287–0.365 after.
- Parsing 100,000 distinct ISO timestamps in one process: 6.719 CPU-seconds with the legacy parser, 0.076 with the new parser. Every parsed date and the checksum matched.

The larger fixture has 4,000 archives and 77,872,320 bytes, with about twice the installed cache's event count. Its peak resident memory stayed close to 689 million bytes before and after. Plist decoding remains expensive: the warm fixture used 8.63 CPU-seconds before and 10.66 afterward under different host load. That path was not changed, and there is no claim of reduced decoding cost or a measured whole-app CPU percentage after installation. OpenCode result reuse has an estimated 16 MiB cache budget; no large decoded-log cache was added. Import progress publishes at most once per second.

All 106 regular Swift tests and nine Python collector tests passed. The four optional release benchmarks passed, as did an isolated 50-test release subset covering import, cost, calendar and parser behavior. Regressions cover corrupt-account startup/recovery, bounded concurrency, cancellation, queued manual refresh, reset jitter and legacy warning migration, WAL writes and database replacement, expiry and future rows, DST boundaries, and retained partial-import warnings. Tray sizing, scrolling with both scrollbar settings, colors, English layout and activity persistence passed. The source app bundle built and passed deep signature verification and bundled layout/persistence checks. The direct-download updater build also passed.

Synthetic previews were reviewed for the tray, usage page and 30-day calendar. Offscreen SwiftUI did not expose accessibility descendants on this Mac, so the native check reports that limitation; live VoiceOver verification remains outstanding. The review checks left the installed app unchanged; the subsequent release installation is recorded above.

Reproduce the optional measurements with:

```sh
JUICEBAR_BENCHMARK=1 swift test -c release --filter ActivityPerformanceTests
JUICEBAR_BENCHMARK=1 swift test -c release --filter LogDateParserTests/testDateParsingBenchmark
```

## Claude installation discovery, 28 September

A live `get_usage` probe reproduced the stalled five-hour window: Claude 2.1.241 at `/opt/homebrew/bin/claude` returned 58% used with an expired reset and 95% weekly usage. Changing only the executable to the native 2.1.283 installation returned 3% used with a future reset and 96% weekly usage. Claude discovery now prefers the native installation. Explicit paths still override discovery; package-manager fallbacks and Codex discovery retain their previous behavior.

The installation-selection regression failed before the change and passed afterward. `swift test` passed 82 tests, with the optional performance test skipped. Parser and cached-display regressions now reject unknown top-level Claude fields, including Iguana Necktie and Nimbus Quill, while retaining supported windows and Fable. Native tray checks confirm those fields consume no space. The installed app was configured through its account editor to use the native CLI, without replacing the installed release. Its saved settings and fresh observation were checked, and the UI showed 97% session quota remaining and 4% weekly quota remaining.

## Juicebars 0.1.8 release, 28 September

Version 0.1.8, build 10, includes the additional usage importers and Claude fixes. All 82 regular Swift tests and nine Python collector tests passed; the optional performance workload was skipped. Persistence, both scrollbar configurations and direct-updater compilation passed locally and in both PR CI runs. Main and tag CI also passed. English and German previews were refreshed; the website was checked at 1280 and 390 px without horizontal overflow or missing images.

The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. All four downloaded GitHub assets matched their local originals. Copying the public DMG's app preserved its signature and notarization. The Sparkle archive passed Ed25519 verification; a changed byte caused rejection.

Installed 0.1.7 first exercised a localhost feed with a missing archive. Sparkle reported the download error and left 0.1.7 unchanged. The real 0.1.8 candidate could be dismissed and offered again, then downloaded, installed and relaunched as build 10. Recorded account/settings/source hashes were unchanged, both usage caches remained present, and quota observations increased from 7,130 to 7,148. Claude showed current session/weekly usage and Fable without Iguana Necktie. The temporary feed override was removed before promoting the same tested assets to stable. Second-Mac installation remains untested.

## Juicebars 0.1.9 release, 5 October

Version 0.1.9, build 11, fits the menu bar window to its content and adds hover details to quota bars. The installed 0.1.8 window measured 784 pt for 747 pt of content; a fresh launch measured 747 pt, so the window had kept an earlier, larger height. All regular Swift tests, the Python collector tests and the tray layout check passed locally; CI passed on the release commit. English and German previews were refreshed.

The app and DMG passed Developer ID signing, Apple notarization, stapling and Gatekeeper assessment. All four GitHub assets matched their local originals, and the stable feed served build 11. Window fitting and the hover popover inside the live menu bar panel were not verified by automation, because the test instance's status item could not be opened by script. The old-to-new update is being performed on the maintainer's installed 0.1.8.

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

### Quota hints and tray scrolling, 26 September

The quota bars keep their provider color. Hints show an approaching target crossing, imminent exhaustion or an exhausted limit; the bar and diamond already express the current balance. Predictions use recent history and appear only for events before reset within the next two hours, with exhaustion taking priority. Target crossing accounts for the moving marker: time = current headroom / (measured usage rate − steady target rate). It requires a positive headroom, a faster measured rate, and at least 5% of the window elapsed. Failed, stale and expired measurements do not produce current-status hints; notification preferences are unchanged.

The shared forecast engine averages interval rates from at most the last hour with an exponential ten-minute half-life. Weights cover elapsed time, including observed zero-usage intervals, so a denser polling schedule does not itself change the rate. It requires three measurements spanning at least five minutes and a usage increase within ten minutes. A measurement gap over ten minutes discards the preceding segment. No yesterday-average fallback is used; after a pause, forecasts remain absent until recent observations support them again. Tests cover weighting, polling cadence, idle periods and gaps.

The quota tests cover the moving target, stable or growing headroom, a crossing beyond the prediction horizon, usage already above the target, and limit-warning priority. `--verify-tray-layout` reproduces the reported 90% used / roughly 94% expected case and checks the rendered bar for its provider color. It also verifies that a fitting tray has no native scroll view and that an overflowing tray can scroll with its indicators hidden. Both German and English pass, including the 500 pt height constraint. `--render-previews` additionally writes `quota-states-{remaining,used}-{de,en}.png` for visual inspection of the hints in both display modes. These checks do not install or publish a release.

The first release candidate, tagged `v0.1.6`, failed the macOS CI scrollbar check and was not published. The same failure reproduces locally with `--verify-tray-layout -AppleShowScrollBars Always`: SwiftUI's `.hidden` still permits the system to show a scroller. The corrected 0.1.7 candidate uses `.never`; the original check and the forced Always case both pass locally. CI now runs both configurations.

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


## Juicebars 0.1.7 quota hints and scrollbar fix, 26 September

All 62 Swift tests, three SSH collector tests, activity persistence and native tray checks pass. The tray checks include the system setting that always shows scrollbars. Both macOS CI runs for release commit `8c38d6e` passed. Updated synthetic screenshots were checked on the website at 1280 and 390 px without horizontal overflow or broken images.

The app and DMG passed Developer ID signing, Apple notarization, ticket stapling and Gatekeeper assessment. The downloaded public DMG matched the local artifact, and copying its app out preserved signature and notarization. The Sparkle archive passed Ed25519 verification; a modified copy failed.

Installed 0.1.5 found the 0.1.7 candidate. Dismissing the offer and checking again worked. Sparkle then downloaded, installed and relaunched 0.1.7 build 9. Four configuration hashes remained identical, both usage caches were retained, and quota observations increased from 1,789 to 1,805. Codex, Claude/Fable and OpenCode Go returned fresh quotas. The live popover showed the new forecast text without a scroll view when its content fitted.

A separate localhost test feed deliberately pointed to a missing update archive. Sparkle displayed a download error and left 0.1.5 installed; the error could be dismissed before the successful update. The temporary feed override was removed, restoring the normal stable feed. The same tested release assets were then promoted to stable. Installation on a second Mac remains outstanding.

## Additional activity formats and import performance

The additional-source tests use synthetic Gemini JSON/JSONL, Cline SDK v1, Roo, Qwen and Kilo SQLite files. They compare local output with the bundled SSH collector, check cache and reasoning semantics, and verify that SQLite WAL writes invalidate cached metadata. No real sessions or credentials are test fixtures.

Run the optional workload measurement with:

```sh
JUICEBAR_BENCHMARK=1 swift test --filter ActivityPerformanceTests
```

On the development Mac on 2026-09-28, the debug build read 10,000 Gemini JSONL entries in about 1.8 seconds initially and 0.06 seconds from cache. A complete import of 20,000 Kilo messages took about 0.99 seconds initially and 0.26 seconds unchanged after adding the database/WAL fingerprint cache, down from 0.95 seconds unchanged. These are local synthetic measurements, not timing guarantees for other machines or SSH hosts.

The catalog signing helper now fails without opening authentication UI. Running an unsigned temporary build against the existing key returned status -25293 immediately. The wrapper also rejected the outdated installed helper before invoking it. The regular application already disables authentication UI for its Keychain reads; activity log parsers do not access Keychain.
