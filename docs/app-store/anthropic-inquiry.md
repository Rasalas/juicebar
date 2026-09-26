# Claude integration inquiry

Draft only, not sent. No request to contact Anthropic has been made by the maintainer. The documentation's [authentication section](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use) directs questions about permitted authentication methods to Anthropic sales.

## Message

Subject: Permitted subscription quota monitoring and Mac App Store packaging for Juicebar

I'm developing Juicebar, an independent open-source macOS menu-bar utility with a free direct download and a proposed paid Mac App Store edition. It displays the user's remaining coding-subscription quotas and reset times and issues local consumption warnings. It does not provide model inference or resell Claude usage.

The current direct edition invokes the user's unmodified Claude Code CLI and reads `get_usage` control responses. Authentication and requests stay inside Claude Code. Juicebar does not extract Claude OAuth tokens, read browser cookies or call private subscription endpoints itself. It does not send model prompts to obtain quota updates.

We tested the documented statusLine alternative. It supplies the five-hour and weekly windows, but does not give us equivalent model-specific coverage or fresh background values when Claude Code is inactive. We will not sell a store edition that loses these capabilities.

Could you clarify the permitted implementation for this use case?

1. May a local third-party quota monitor periodically invoke `get_usage` through unmodified Claude Code with the user's own subscription login, without model requests? Is prior approval required, and what polling or backoff limits should it follow? This question applies to both the free direct edition and the proposed paid edition.
2. May the store edition bundle Claude Code and let each user authenticate through its own built-in flow, without Juicebar handling credentials? Your binary-hosting terms and the SDK overview's restriction on third-party subscription login appear to address different cases. Which applies to this quota-only utility?
3. Apple documents signing embedded helper tools with the app developer's identity and sandbox inheritance entitlements. Would replacing only Claude Code's code signature and entitlements for that purpose count as modifying the binary under your terms? If it is not permitted, do you offer a distributable component or another supported integration suitable for an App Sandbox application?
4. Is there a documented quota-only API or export that includes model-specific windows, subscription tier and any available reset-offer expiry, and can refresh without an active model conversation?

We want to use a supported integration and respect your account and redistribution rules. We will not treat a successful technical test as permission to distribute it. Repository: https://github.com/Rasalas/juicebar

## Documentation reviewed on 26 September 2026

- [Binary hosting and authentication](https://code.claude.com/docs/en/legal-and-compliance)
- [Agent SDK overview](https://code.claude.com/docs/en/agent-sdk/overview)
- [Status line](https://code.claude.com/docs/en/statusline)
- [Apple helper-tool packaging](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)

The inquiry deliberately asks for clarification. It does not assert that Anthropic prohibits quota displays, permits Juicebar, or guarantees an account will never be restricted.
