# Signed model catalog

`Sources/JuicebarCore/Resources/model-catalog.json` contains confirmed provider-scoped aliases and current standard USD prices per million tokens. Original model names and event IDs in logs remain unchanged. Each alias and rate carries a source URL and verification date. Unknown models remain unpriced.

The app ships a verified baseline and checks `https://rasalas.github.io/juicebar/catalog/model-catalog.signed.json` at most once per day, during automatic history refresh. Settings can disable the check. The request contains no credentials or usage data. It is subject to normal web-host request metadata.

The envelope signs the exact decoded payload bytes with Ed25519. The public key is bundled in `catalog-public-key.txt`; the private key stays in the maintainer's login Keychain under service `app.juicebar.catalog-signing`. This key is independent of app/update signing. No private keys are in GitHub Actions.

Validation checks the signature, schema, positive revision, payload size, unique provider/name pairs, known canonical targets, finite nonnegative rates, HTTPS source URLs and valid dates. Downloads are capped at 1.5 MB and 20 seconds. Only a newer revision replaces the active document. No scripts, binaries or provider code are loaded.

The last accepted envelope is written atomically in the app's data folder. The previous verified envelope is retained. Startup uses the newest valid cache, otherwise the previous copy, otherwise the bundle. A failed download or malformed response leaves current pricing in use. The displayed date is the catalog's verification date, not the last attempted fetch. This does not claim that prices are still current when offline.

## Publish a change

1. Confirm names/prices with primary provider sources. Update the source date for every changed entry. Do not infer an alpha model's identity from its behavior.
2. Edit the bundled JSON, increment `revision`, and run `swift test`.
3. Sign with the existing local Keychain key:

   ```sh
   swift scripts/sign-catalog.swift Sources/JuicebarCore/Resources/model-catalog.json site/catalog/model-catalog.signed.json
   ```

4. Review the data diff and verify the envelope against the bundled public key. Commit the catalog and envelope; the Pages workflow publishes `site/`.
5. Confirm the public URL serves the signed file. Existing installations recalculate retained usage on the next import. Displayed equivalents can change; provider-reported costs do not.

To correct a published catalog, publish corrected content with a higher revision. Never lower a revision. Initial key creation uses `--create-key --public-key`; do not regenerate the key for ordinary updates. Rotating a compromised signing key requires a new application release with a new trusted public key.
