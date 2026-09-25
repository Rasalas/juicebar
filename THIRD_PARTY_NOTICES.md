# Third-party notices

Juicebar's own code is available under the [MIT license](LICENSE).

## Provider artwork

The OpenAI, Claude and OpenCode artwork is derived from the harness assets in [T3 Code](https://github.com/pingdotgg/t3code/tree/d06f0ff1048d42a156824765316c5a2dc54f5bca/apps/marketing/public/harnesses), copyright 2026 T3 Tools Inc. The full MIT notice is included in [assets/providers/LICENSE-T3](assets/providers/LICENSE-T3). Raster derivatives are bundled in the application.

Names and logos identify compatible services. Juicebar is an independent project and is not endorsed by OpenAI, Anthropic, OpenCode or T3 Tools. The software licenses do not grant ownership of those trademarks.

## Direct-download updater

Direct-download builds use [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/tree/2.10.0), an open-source macOS update framework. Its [license and bundled component notices](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE) remain inside the distributed framework and are copied into the application notices when packaging a direct build. Source builds without `JUICEBAR_DISTRIBUTION=direct` do not include Sparkle.

## System components and research

Juicebar links the SQLite library supplied by macOS. No third-party CLI executable is redistributed: Codex, Claude Code, OpenCode and SSH integrations use the user's existing installation. Their accounts and services retain their own terms.

[Project comparisons](docs/project-comparison.md) and [integration contracts](docs/integration-contracts.md) document implementation references and provider behavior. Referencing another project's design does not imply an affiliation.
