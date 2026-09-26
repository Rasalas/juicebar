# Mac App Store sandbox feasibility

Measured 25–26 September 2026 on the development Apple Silicon Mac. This is an isolated prototype, not the shipping application or an App Review decision. The 26 September tests below supersede the original Codex integration blocker.

The probe uses a separate bundle ID and container. Entitlements enable App Sandbox, outgoing network connections, user-selected read/write files and app-scoped bookmarks. It has no full-disk access, automation entitlement or temporary sandbox exceptions. Provider credentials and conversation content are never written to its report.

## Results

| Operation | Without selected folders | After explicit folder selection |
| --- | --- | --- |
| Codex profile | Denied | Readable, including after restart |
| External Codex binary | Not available to the sandbox | File readable, execution still denied |
| Codex app-server quota integration | Unavailable | Unavailable because CLI cannot launch |
| Claude log directory | Denied | Readable |
| Claude credential data in existing Keychain item | Authentication failed with interaction disabled | Not established; folder selection does not grant Keychain access |
| External Claude CLI | Unavailable | Not established; same external-executable restriction applies |
| OpenCode auth/database | Denied | Readable; database parsed successfully |
| OpenCode Go quota endpoint | No usable key | Successful authenticated read, three quota windows |
| SSH using existing alias, host key and key login | Failed | Successful read-only remote health command |

The OpenCode history probe found 13 days. This is evidence of database access, not a promised retention boundary. The SSH probe runs only a small health command; the complete remote collector still needs validation in a finished sandbox app, including different key/agent configurations.

The Codex executable was tested by opening it for reading and by trying `ProcessClient` directly, independently of executable discovery. Reading succeeded; launch returned `NSCocoaErrorDomain` code 4. Apple's [sandbox file access documentation](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox) explicitly says user-selected file access does not permit running programs outside the bundle or app/group container. Selecting a wider folder does not solve that restriction.

The Keychain result is scoped to this separately signed probe. It is not evidence that a properly authorized native store client can never use Keychain. A metadata-only lookup succeeded, while requesting credential data with interaction disabled returned `errSecAuthFailed`. No user credential prompt was forced.

## Consequence

Do not submit the direct app unchanged. OpenCode and file-based history have a viable sandbox path, and SSH worked in this configuration. Codex and Claude need a native provider integration or a deliberately designed, compliant bundled component. A store edition missing the primary subscription integrations would not meet the product's purpose.

## Bundled Codex and local Claude export, 26 September

| Test | Measured result |
| --- | --- |
| Bundled Codex 0.157.0, sandbox inheritance entitlements | Starts and initializes |
| Official browser login into an empty app-owned profile | Completes; real quotas and one reset offer returned |
| Second quota read in the same process | Succeeds |
| Relaunch with zero security-scoped folder grants | Reads persisted login and real quotas |
| `account/read` with `refreshToken: true`, isolated profile only | Succeeds, followed by successful quota reads |
| Claude Code 2.1.241 statusLine export after a real test response | Exports both five-hour and seven-day limits with reset timestamps |
| Sandboxed read of that Claude export, with the previously selected folder | Succeeds; two active windows |
| Sandboxed read with zero folder grants | Correctly denied, Cocoa error 257 |
| Probe restart after the test Claude session exits | Reads the same observation with its original receipt timestamp |

Codex is copied into `Contents/Helpers` for this local experiment and re-signed with `app-sandbox` and `inherit`. The upstream installed executable is untouched. The helper inherits the sandbox, not an exception to it. Its working directory must be app-owned: the old `/private/tmp` default caused startup to exit with EPERM. Apple's [helper guidance](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app) and the official [Codex protocol](https://learn.chatgpt.com/docs/app-server) describe the mechanisms used.

The Codex login uses its official browser flow and a loopback callback listener, requiring the network-server entitlement. Device-code login was unavailable because the account setting was disabled; the experiment did not change that security setting. Credentials are managed by Codex in the probe container, not copied from the user's CLI. Production work remains for credential storage, clean-account onboarding, account switching, cancellation, expired/revoked credentials, pinned distribution assets and notices. A successful explicit refresh request is not a days-long expiry test.

The Claude exporter writes only validated quota windows and a local receipt time. It excludes conversation text, paths, session IDs and tokens. `receivedAt` is **not** evidence that a server was polled at that time. Re-rendering a status line may reuse data. Expired windows are excluded when read, and absent or malformed data never turns into a synthetic zero. Tests cover field filtering, malformed percentages, invalid reset times, bounded input and expiration.

The actual CLI test used a separate, trusted empty project with project-only settings. Passing statusLine solely through `--settings` while using an empty `--setting-sources` did not invoke it in 2.1.241; project settings did. No global Claude settings were changed. Only short explicit test responses were generated. Automatic monitoring never sends prompts. Claude's ordinary terminal operation and the test exporter run outside the app sandbox; the consumer runs inside it with an explicit folder grant. This is not proof that the sandbox app can launch the external CLI.

The official [statusLine documentation](https://code.claude.com/docs/en/statusline) describes the supported data. Model-specific limits, reset-offer inventory, account identity/multiple accounts and a fresh background poll without an active CLI are not covered by this prototype. The original direct Claude OAuth reset supplement has been removed; see [provider access](provider-access.md). Before calling a store edition equivalent to the direct app, resolve those differences or describe them clearly. Review-compliant exporter onboarding and preservation of an existing user status line also remain unfinished.

Next implementation work:

1. Turn the measured bundled Codex integration into production onboarding and validate failure/account-switch paths. Pin the component and preserve its license/notices. It must always inherit the app sandbox.
2. Introduce scoped folder connections in the production app. Persist bookmarks, refresh stale bookmarks, release scopes on disconnect and retain history when a folder is temporarily unavailable. The prototype demonstrates the mechanism but is not a production account setup flow.
3. Turn the credential-free Claude export into a reversible folder connection, preserve existing status-line output and expose freshness/coverage honestly. Do not replace missing fields with private OAuth calls.
4. Exercise the full SSH collector, keys requiring an agent and offline/reconnect behavior within the sandbox.
5. Add a store build that excludes Sparkle and external funding links as appropriate, sign with the distribution profile, validate the package and run the same functional checks as the direct app.
6. Finalize metadata, privacy answers, account/legal details and price, then submit for review. Drafts and sample-data screenshots live in `docs/app-store/`.

## Reproduce

```sh
bash scripts/build-sandbox-probe.sh
open -n "$HOME/Applications/Juicebar Sandbox Probe.app" --args \
  --home="$HOME" --codex=/absolute/path/to/codex --claude=/absolute/path/to/claude
# Repeat with --grant and select only the folder required for the next test.
# Optional --folder=/initial/folder sets the dialog location; --ssh=workstation tests an existing alias.
```

The report is in the probe container's `Data/Library/Application Support/probe-report.json`. It contains only operation outcomes and aggregate counts. Selected bookmarks remain in the probe's preferences for a subsequent restart test. Do not include local bookmarks, reports with host details or credentials in the repository.

### Bundled Codex

```sh
JUICEBAR_PROBE_CODEX="$(command -v codex)" bash scripts/build-sandbox-probe.sh
open -n "$HOME/Applications/Juicebar Sandbox Probe.app" --args --bundled-codex --no-grants --login-browser
# Open the URL in the temporary, mode-0600 codex-login.json in the probe's Application Support folder.
# Complete the official browser flow within three minutes. The handoff file is then removed.
open -n "$HOME/Applications/Juicebar Sandbox Probe.app" --args --bundled-codex --no-grants
open -n "$HOME/Applications/Juicebar Sandbox Probe.app" --args --bundled-codex --no-grants --refresh
```

`bundled-codex-report.json` records only outcomes and quota metadata. `codex-diagnostic.txt` is a private local stderr diagnostic; do not attach it to public reports without reviewing it. This packaging is a local feasibility build, not a redistributable store package.

### Claude statusLine

```sh
bash scripts/prepare-statusline-probe.sh
cd "$HOME/Library/Application Support/Juicebar Sandbox Tools/claude-workspace"
claude --setting-sources project --strict-mcp-config --mcp-config '{"mcpServers":{}}' --tools '' --no-chrome
# Use the unmodified CLI normally; the first response supplies quota fields.
open -n "$HOME/Applications/Juicebar Sandbox Probe.app" --args --grant \
  --folder="$HOME/.claude/juicebar-probe" --claude-statusline="$HOME/.claude/juicebar-probe/status.json"
```

Select only that export folder. `claude-statusline-report.json` records receipt time and active quota percentages. Repeat without `--grant` to test persisted folder access, and with `--no-grants` to check denial. Preparation modifies only this isolated test project's settings. Quit the test CLI when finished; there is no background exporter or global hook to remove.
