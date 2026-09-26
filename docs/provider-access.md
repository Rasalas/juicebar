# Provider access and account safety

The product must not trade account safety for more complete quota displays. This applies to the free direct build and the proposed paid store build. No integration can guarantee a provider will never restrict an account; technical success is not provider approval.

## Claude

Anthropic documents a local [statusLine interface](https://code.claude.com/docs/en/statusline) that receives subscription quota percentages and reset times from Claude Code. The store prototype consumes an allowlisted export of those fields, without tokens, account identifiers or conversation content. The exporter has no network access code. It does not create model requests to keep values fresh. If the CLI stops providing data, values age and expire.

The direct build currently reads quotas through the user's unmodified Claude CLI control interface, `get_usage`. This interface appears in the official SDK's [release history](https://github.com/anthropics/claude-agent-sdk-typescript/releases), but that is not an endorsement of Juicebar or a guarantee of compatibility. Authentication and provider requests stay inside the CLI. The statusLine path has clearer public documentation, but its incomplete coverage and passive freshness disqualify it as the only Claude integration for a paid store release.

Version 0.1.3 removes the supplementary direct request to the private Claude subscription endpoint and all extraction of Claude OAuth credentials from Keychain or credential files. Automatic Claude reset-offer inventory is therefore unavailable. Users can still enter an expiry manually; Codex's documented reset inventory is unaffected. Do not restore token extraction as an automatic fallback.

Anthropic's [authentication rules](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) prohibit third-party collection/intermediation of Claude subscription tokens and offering an independent Claude.ai login. Its [binary hosting conditions](https://code.claude.com/docs/en/legal-and-compliance#can-customers-offer-claude-code-in-their-products) separately allow users to authenticate inside hosted, unmodified Claude Code under stated conditions. The [SDK overview](https://code.claude.com/docs/en/agent-sdk/overview#get-started) also restricts offering Claude.ai login or rate limits without prior approval. Those statements do not clearly settle quota-only background monitoring or replacement of the binary's signature for App Store packaging. Neither a launch test nor the existence of `get_usage` settles that question. See the [prepared provider inquiry](app-store/anthropic-inquiry.md).

Do not modify Claude or build an independent subscription login to work around those rules. Unresolved access or redistribution requirements block the paid store release. Omitting Claude features or relying solely on passive exports does not satisfy the maintainer's release requirement. The same access policy applies to the direct build; a free download does not imply provider approval.

## Other providers

Codex uses its documented app-server account interface. The sandbox experiment keeps its own login inside the app container; it does not borrow another application's token. Bundling requires preserving the upstream license/notices and validating each pinned component version.

OpenCode and organization billing adapters use API keys for their intended provider services. Antigravity is not implemented; its documented local statusLine export is the candidate, not a custom Google OAuth client.

New integrations must distinguish documented provider APIs, supported local exports and experimental interfaces. An undocumented schema is not permission to discover private endpoints, extract browser sessions or evade authentication and rate limits. Do not use account rotation, client impersonation or repeated model requests as monitoring mechanisms. For an unclear access method, record the limitation and use a supported source instead.
