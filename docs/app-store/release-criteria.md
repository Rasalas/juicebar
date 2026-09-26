# Paid store release criteria

Maintainer requirement, 26 September 2026: do not sell an incomplete or inferior edition. Submission is authorized once a complete, tested edition meets the requirements below. Current status: blocked, no production store package.

The reference is the current direct edition with the same accounts, logs and settings. Provider limitations shared by both editions must remain explicit. For example, automatic Claude reset-offer inventory currently has no verified supported source. Removing a direct feature solely to achieve parity is not acceptable.

| Capability | Required evidence | Current store evidence |
| --- | --- | --- |
| Codex subscription | Own login, background refresh without a terminal session, all returned limits and reset offers, logout and account switching | Isolated bundled prototype passes login, restart and explicit token refresh. Production onboarding, logout and account switching remain unimplemented. |
| Claude subscription | Provider-permitted integration, background refresh without an active conversation, all model-specific limits available in the direct app, tier, failure and reconnect handling | Passive export fails coverage and freshness requirements. Exact upstream binary passes an isolated `--version` launch. Bundled authentication, quota reads and store packaging remain unproven. |
| OpenCode Go, Zen and API accounts | Same supported account types, quotas, source limitations and history as the direct app; user-controlled connections | Go quota read demonstrated. Production sandbox connections and the full account matrix remain unverified. |
| History and API equivalent | Automatic incremental import, saved history, combined activity, SSH sources and price coverage; no recurring manual import | Selected files and an SSH connection demonstrated. Complete import, restart and reconnect flows remain unverified. |
| Menu bar and warnings | Same selectable limits, ordering, pace markers, forecasts, notifications, sound and expiry reminders | Shared UI and rules exist. End-to-end validation in the production sandbox package remains pending. |
| Installation and updates | Clean installation, explicit folder permissions, revocation handling, data migration, preserved settings/history, no recurring authorization prompts | Direct package tested. Store package and migration remain pending. |

Different update delivery and an initial macOS folder permission are expected platform differences. Requiring an active Claude conversation for fresh quotas is a functional regression, not such a difference. A separate manually installed unsandboxed helper is not an accepted substitute for working store onboarding.

Before submission, record the exact candidate build, provider component versions and results for these scenarios. Sample data, unit tests and the ability to launch a helper do not substitute for real account tests. Missing evidence stays pending. The maintainer's current instruction does not authorize a reduced-feature fallback release.

Provider permission and Apple acceptance are separate requirements. A technically successful private test proves neither. Track the Claude questions in the [provider inquiry](anthropic-inquiry.md) and the measured results in [sandbox feasibility](../sandbox-feasibility.md).
