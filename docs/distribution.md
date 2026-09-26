# Distribution and funding

Decision, 25 September 2026: publish Juicebar as MIT-licensed open source. Keep direct downloads and their updates free. Offer a paid Mac App Store edition when its integrations work within the sandbox and it passes review. No purchase check belongs in quota collection, warnings, history or the direct updater.

The proposed store price is EUR 9.99 once; it has not been configured or published. See the [pricing proposal](app-store/pricing.md). GitHub Sponsors and one-time contributions are optional support channels, not conditions for using the app. Ordinary fixes and provider compatibility updates are included. This does not promise perpetual maintenance.

## Platform status

| Platform | Status | Possible distribution |
| --- | --- | --- |
| macOS | Native SwiftUI/AppKit implementation, macOS 14+, locally tested on Apple Silicon | Free signed/notarized direct build; paid Mac App Store edition after sandbox validation |
| Windows | Not implemented | Microsoft Store, optionally paid, and a free direct package |
| Linux | Not implemented | Free distribution packages or Flatpak; optional paid downloads or elementary AppCenter if its requirements fit |

Windows and Linux are lower priority. SwiftUI/AppKit, Keychain, process handling, notifications and login integration cannot simply be cross-compiled into those apps. Before a port, separate platform-independent models, parsers and rules from OS services, then select a UI and packaging approach based on actual demand. Do not maintain two independent sets of provider semantics or quota rules.

Microsoft supports paid apps and automatic store updates. Current onboarding documentation describes free registration in its new flow; account status still needs checking when a Windows version exists. See [Microsoft Store overview](https://learn.microsoft.com/windows/apps/publish/faq/get-started-with-the-microsoft-store) and [account setup](https://learn.microsoft.com/en-za/windows/apps/publish/partner-center/open-a-developer-account).

Linux has no single equivalent store. elementary AppCenter supports a suggested price, including a user-selected price of zero, but requires a compatible application and submission. See [monetization](https://docs.elementary.io/develop/appcenter/monetizing-your-app) and [publishing requirements](https://docs.elementary.io/develop/appcenter/publishing-requirements). It is not a promise that an arbitrary port can be listed there.

## Update channels

- **Source builds:** no automatic binary replacement. Rebuild from a release tag or update the checkout.
- **Official direct builds:** Sparkle, HTTPS feed, signed archives and Developer ID notarization. Users control automatic checks. No payment or license server is consulted.
- **Mac App Store:** Apple's update delivery. Sparkle is omitted from the build. A store target and sandbox entitlements still need implementation and validation.

Both official channels should use the same source tag and version. Store review can delay availability; a critical direct fix should not wait for that review. Beta builds must use a separate feed if introduced. Preserve usage data and settings across updates and verify migrations against previous versions.

## Model metadata

Aliases and prices ship in the app and can update independently through a signed, versioned data catalog. The implementation validates signatures, schema, size, source dates and revisions, and keeps bundled and previous valid fallbacks. It never loads executable provider code or guesses model identities. See [catalog maintenance](model-catalog.md).

## Mac App Store feasibility

The current app is not sandboxed or store-ready. A separate sandbox prototype retrieves OpenCode Go quotas, supports Codex through a bundled sandboxed component with its own browser login, and reads a credential-free local Claude statusLine export. Claude's coverage and background freshness still differ from the direct edition. See the [measured results and remaining work](sandbox-feasibility.md), plus the [listing draft](app-store/listing-en.md). Store approval is not guaranteed. Do not remove core functionality from the direct edition to force parity; the removal of private Claude OAuth access applies to both editions for account-safety reasons.

Sources: [App Sandbox](https://developer.apple.com/documentation/security/app_sandbox), [sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox), [Apple business models](https://developer.apple.com/app-store/business-models/), [Sparkle setup](https://sparkle-project.org/documentation/).

The maintainer authorized App Store submission on 25 September 2026. Submission remains pending on the measured sandbox blockers above; the direct build must not be submitted as a working store edition.
