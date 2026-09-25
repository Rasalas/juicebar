# Privacy

Juicebar stores usage information on your Mac. It has no analytics, advertising SDK, Juicebar account or hosted usage service.

## What the app reads

- Subscription quotas through the Codex and Claude Code CLIs and supported provider endpoints. These tools may contact their providers using your existing login.
- Local Codex, Claude Code and OpenCode logs and databases to extract timestamps, model identifiers, token counts and reported costs. The parser reads log files containing conversations, but does not retain or upload conversation text.
- Claude's statistics cache to recover aggregate days when detailed logs are unavailable.
- Optional SSH sources that you configure. The bundled collector runs on the selected host and returns usage metadata, not conversations. No collector is installed on that host.

Keys entered into Juicebar are stored in the macOS Keychain. Some integrations read existing CLI credentials or their Keychain entries. Connecting a source can require an operating-system permission prompt. Juicebar does not ask for full disk access.

## What is stored

Settings, configured account labels and SSH hosts, quota snapshots, warning history and usage metadata are stored under `~/Library/Application Support/Juicebar`. Usage caches retain up to 90 days of metadata; quota storage is capped at 12,000 snapshots and warning history at 180 days. These files can include model names, source paths and opaque message identifiers. They should not be attached to public issues.

Original CLI logs are never modified. Removing Juicebar does not remove these application-support files or Keychain items automatically.

## Network connections

Enabled providers receive their required authenticated usage requests. SSH connects to your configured hosts. Juicebar does not send usage history to its maintainer.

Official direct-download builds can check for app updates through Sparkle using GitHub-hosted release metadata. The host sees ordinary connection metadata such as IP address and the update request. Sparkle system-profile reporting is disabled. Automatic checks can be disabled in settings. Source builds do not enable this updater. Links to GitHub, documentation and funding pages open in your browser and are subject to those services' policies.

The model alias and price catalogs currently ship with the app. A separate remote catalog is planned but is not active.

Notifications may show provider names and usage values on your desktop or lock screen according to your macOS notification settings.

## Reporting a problem

Use [GitHub Issues](https://github.com/Rasalas/juicebar/issues) for ordinary bugs, with personal details removed. For credential exposure or another security concern, follow [SECURITY.md](SECURITY.md).
