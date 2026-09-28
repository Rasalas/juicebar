# Claude quota fields

Checked on 2026-09-28 against upstream T3 Code commit `d15210cd3da79f9a1a495a6309d912d76362a046`, upstream CodexBar commit `22fbf3559024c9106e3f59847f86e490cafce87b`, and Anthropic's published `@anthropic-ai/claude-agent-sdk` version `0.3.283`.

## What the other applications display

T3 Code explicitly maps `five_hour` and `seven_day`. It adds model-specific weekly rows from `rate_limits.model_scoped[]`, using each entry's server-supplied `display_name`. Its mapper does not enumerate arbitrary top-level usage keys. Neither `iguana_necktie` nor `nimbus_quill` gets a row. Streamed `seven_day_overage_included` updates reuse a model name previously supplied by a usage response; an unnamed bucket is ignored. [T3 Code mapper](https://github.com/pingdotgg/t3code/blob/d15210cd3da79f9a1a495a6309d912d76362a046/apps/server/src/provider/Layers/claudeUsageLimits.ts#L33-L192)

CodexBar's OAuth response decoder recognizes `iguana_necktie`, but the decoded property has no consumer in the inspected source tree. The display mapper selects known session, weekly and model windows, plus separately mapped Routines and scoped weekly limits. `nimbus_quill` does not appear in the source tree. Decoding Iguana therefore does not mean displaying it or knowing its product meaning. [OAuth decoder](https://github.com/steipete/CodexBar/blob/22fbf3559024c9106e3f59847f86e490cafce87b/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift#L261-L297), [display mapping](https://github.com/steipete/CodexBar/blob/22fbf3559024c9106e3f59847f86e490cafce87b/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift#L1044-L1136)

For the newer raw API `limits[]` format, CodexBar accepts entries with `group == "weekly"`, `kind == "weekly_scoped"`, a finite percentage and a nonempty model display name. It excludes generic "All models" scopes and deduplicates IDs. It intentionally does not filter on `is_active`, because its maintainers observed enforceable limits with that flag set to false. [Scoped mapper](https://github.com/steipete/CodexBar/blob/22fbf3559024c9106e3f59847f86e490cafce87b/Sources/CodexBarCore/Providers/Claude/ClaudeScopedWeeklyLimitMapper.swift#L14-L45), [OAuth adapter](https://github.com/steipete/CodexBar/blob/22fbf3559024c9106e3f59847f86e490cafce87b/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift#L1215-L1229)

## What Anthropic documents

The published SDK's `SDKControlGetUsageResponse` defines the known top-level windows and `model_scoped`. Its comment identifies `model_scoped` as weekly model windows from the server's `limits[]`, filtered by an overage-included-model allowlist. `display_name` is explicitly a server-supplied label, with Fable as its example. Neither opaque key appears in this response type. [Anthropic SDK 0.3.283 declarations](https://unpkg.com/@anthropic-ai/claude-agent-sdk@0.3.283/sdk.d.ts)

The official status-line documentation describes the five-hour and seven-day usage percentages and reset timestamps. It provides no interpretation of `iguana_necktie` or `nimbus_quill`. Targeted searches and the inspected first-party SDK did not establish an official meaning for either name. This is a scoped research result, not proof that no private or historical documentation exists. [Claude Code status-line fields](https://code.claude.com/docs/en/statusline#available-data)

## Policy for Juicebar

Use an explicit allowlist for understood top-level windows and the structured model-scoped format for model rows. Ignore unknown top-level keys for display and limit calculations, including `iguana_necktie` and `nimbus_quill`. Keep named model quotas such as Fable.

The defensible inference is that these are opaque response keys without a verified user-facing meaning. Neither inspected application establishes what products or experiments they represent. Do not rename them to speculative products or treat a prettified API key as a meaningful quota label. Hiding them is a display policy; it does not establish that the server never uses them internally.
