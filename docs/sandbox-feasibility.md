# Mac App Store sandbox feasibility

Measured 25 September 2026 on the development Apple Silicon Mac. This is an isolated prototype, not the shipping application or an App Review decision.

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

Next implementation work:

1. Replace external CLI quota calls with native authenticated provider requests or an approved bundled integration. Validate login, token refresh, account switching, provider terms and failure behavior. Do not copy a CLI into the container merely to evade the restriction.
2. Introduce scoped folder connections in the production app. Persist bookmarks, refresh stale bookmarks, release scopes on disconnect and retain history when a folder is temporarily unavailable. The prototype demonstrates the mechanism but is not a production account setup flow.
3. Validate a user-approved Claude authentication path without recurring Keychain prompts. Never silently broaden access to unrelated credentials.
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
