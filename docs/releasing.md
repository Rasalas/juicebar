# Releasing Juicebar

Source publication is independent of the paid store edition. The current repository has no notarized public download and no App Store listing. Never advertise a development CI artifact as a supported signed release.

## Source and CI

Normal builds have no Sparkle dependency and no automatic update checks. The macOS workflow runs Swift and Python tests, persistence and tray checks, builds a development artifact, and separately compiles the direct-download variant. A CI artifact is ad-hoc signed.

`JUICEBAR_DISTRIBUTION=direct` includes the pinned Sparkle dependency. `Package.resolved` records the resolved revision. The packaging script copies Sparkle into the app, signs nested components before the outer bundle, and includes third-party notices. Unknown distribution flavors fail rather than pretending to be store-ready.

## One-time direct-release setup

1. Obtain a **Developer ID Application** certificate with its private key in the maintainer's macOS Keychain. Apple Development and Apple Distribution certificates are not substitutes. Do not revoke existing certificates.
2. Resolve Sparkle and generate its signing key in the Keychain:

   ```sh
   JUICEBAR_DISTRIBUTION=direct swift package resolve
   .build/artifacts/sparkle/Sparkle/bin/generate_keys --account juicebar
   ```

   Keep an encrypted backup outside the repository. The public key is embedded in direct builds; never commit/export the private key into build artifacts.
3. Configure a Keychain profile for `xcrun notarytool`, using an appropriate App Store Connect API key or Apple-supported authentication. Keep credentials out of shell history and repository files. `xcrun notarytool store-credentials --help` describes the interactive flow.
4. Verify signing and notarization on a development archive, then test an installation on another Mac.

## Prepare a release

Run the documented validation suite first. Use a clean checkout of the source tag, a strictly increasing build number and the same marketing version for all distribution channels. No license check or payment flag is part of the update flow.

```sh
export JUICEBAR_VERSION=0.1.0
export JUICEBAR_BUILD=1
export JUICEBAR_SIGN_IDENTITY='Developer ID Application: YOUR NAME (TEAMID)'
export JUICEBAR_NOTARY_PROFILE=juicebar-notary
bash scripts/package-release.sh
```

The script builds for the current Mac architecture, notarizes the app, staples its ticket and creates the signed Sparkle appcast and checksum under `dist/releases/<version>/`. It does not create a GitHub release. The feed's archive URLs point to that version's release assets. A universal or separate Intel release requires explicit build and hardware validation first.

Before publishing, install an older signed build against the candidate feed and complete an update. Verify signature rejection for a modified archive and check that settings, Keychain access and usage history survive. Test cancellation and a failed download. Do not enable automatic installation by default; update checks are enabled in official builds and remain user-configurable. Sparkle system-profile reporting is disabled.

Upload the archive, `appcast.xml` and `SHA256SUMS.txt` together to a draft GitHub release named `v<version>`. Inspect the release notes and download links, then publish and designate it as latest. The stable feed URL is `https://github.com/Rasalas/juicebar/releases/latest/download/appcast.xml`. Every latest binary release must include that asset. Do not designate a source-only announcement or beta release as latest once this feed is in use.

Keeping a release draft prevents a partially uploaded update from reaching users. For a bad release, withdraw its feed entry and ship a corrected build with a higher build number; don't silently replace an already distributed binary.

## App Store and remaining work

The current build script intentionally does not produce store packages. A separate sandboxed target and provider-access feasibility work are required. Exclude Sparkle and review external funding links for that distribution. Store updates go through Apple; ordinary compatibility/security fixes remain included.

Separately fetched signed model metadata, beta channels and automated release publishing are planned, not implemented. The local packaging script is intended to establish a verified release procedure before credentials are introduced into CI.

References: [Developer ID and notarization](https://developer.apple.com/developer-id/), [Sparkle](https://sparkle-project.org/documentation/).
