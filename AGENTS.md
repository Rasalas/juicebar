# Release tests

- Run failed-download, cancellation and corrupted-archive tests only in an isolated test copy with its own bundle identifier, data directory and Sparkle preferences. Never trigger deliberate update errors in the user's installed Juicebars app.
- Use the installed app only for a successful update from a valid, fully prepared candidate. Preserve its settings and history. Remove any temporary feed override and stop its test server before finishing, including after a failed test.
- Before preparing, testing or publishing a release, read [docs/releasing.md](docs/releasing.md).
