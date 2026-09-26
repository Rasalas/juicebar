# Privacy

Juicebars stores usage information on your Mac. It has no analytics, advertising SDK, Juicebars account or hosted usage service.

## What the app reads

- Subscription quotas through the Codex and Claude Code CLIs and supported provider endpoints. These tools may contact their providers using your existing login.
- Local Codex, Claude Code and OpenCode logs and databases to extract timestamps, model identifiers, token counts and reported costs. The parser reads log files containing conversations, but does not retain or upload conversation text.
- Claude's statistics cache to recover aggregate days when detailed logs are unavailable.
- Optional SSH sources that you configure. The bundled collector runs on the selected host and returns usage metadata, not conversations. No collector is installed on that host.

Keys entered into Juicebars are stored in the macOS Keychain. OpenCode can use an API key from its local authentication file. Codex and Claude subscription authentication stays with their CLIs. From version 0.1.3, Juicebars no longer reads Claude OAuth tokens from credential files or Keychain, and no longer calls Claude's private subscription endpoint for reset offers. Connecting a source can require an operating-system permission prompt. Juicebars does not ask for full disk access.

## What is stored

Settings, configured account labels and SSH hosts, quota snapshots, warning history and usage metadata are stored under `~/Library/Application Support/Juicebar`. Usage caches retain up to 90 days of metadata; quota storage is capped at 12,000 snapshots and warning history at 180 days. These files can include model names, source paths and opaque message identifiers. They should not be attached to public issues.

Original CLI logs are never modified. Removing Juicebars does not remove these application-support files or Keychain items automatically.

## Network connections

Enabled providers receive their required authenticated usage requests. SSH connects to your configured hosts. Juicebars does not send usage history to its maintainer.

Official direct-download builds can check for app updates through Sparkle using GitHub-hosted release metadata. The host sees ordinary connection metadata such as IP address and the update request. Sparkle system-profile reporting is disabled. Automatic checks can be disabled in settings. Source builds do not enable this updater. Links to GitHub, documentation and funding pages open in your browser and are subject to those services' policies.

A model alias and price catalog ships with the app. Juicebars can check once per day for a signed catalog at `rasalas.github.io/juicebar/`. No credentials, model names or usage data are sent in that request. GitHub Pages receives ordinary connection metadata. Automatic catalog checks can be disabled separately in Settings. Invalid updates leave the last valid catalog in use.

Notifications may show provider names and usage values on your desktop or lock screen according to your macOS notification settings.

## Reporting a problem

Use [GitHub Issues](https://github.com/Rasalas/juicebar/issues) for ordinary bugs, with personal details removed. For credential exposure or another security concern, follow [SECURITY.md](SECURITY.md).
