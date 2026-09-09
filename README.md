# BotWorkspace

An independent, open-source native macOS workspace for named AI teammates.
Built with **SwiftUI, AppKit and Core Data**, using only Apple frameworks.
The repository name preserves its original [grok-clone idea capsule](PROPOSAL.md).

**Experimental source release, not a finished AI client.** Bots, groups, drafts
and paused routines persist locally. Native provider settings, streamed replies,
explicit group targeting, Stop and Retry are wired to the provider core and tested
with offline fixtures. Real Keychain/signing and live-provider verification remain
open. No Grok Bot/Cursor service, subscription,
remote computer or private API is included; this project is not affiliated with them.

## Run the local app

```sh
scripts/native-app.sh run
scripts/native-app.sh test
scripts/native-app.sh smoke
scripts/native-app.sh provider-smoke # offline fixture; no key or live network
```

The `.app` is built at `Prototypes/NativeShell/.build/BotWorkspace.app`. It opens an empty workspace on first use and keeps data inside its macOS sandbox. **No provider is configured by default.** Settings offers Z.ai general API, local 9router, OpenAI Platform and custom setup templates. Enter the endpoint/model/key, then select the provider and (for groups) the replying bot in the composer. Without a usable credential, the draft is retained.

Protected Keychain access requires authorized signing. For an ad-hoc local build, explicitly choose **This session only** to keep the key in process memory until quitting; re-enter it on the next launch. There is no automatic fallback or plaintext credential file. See [provider setup](docs/PROVIDER-SETUP.md) and [integration/signing limits](docs/PROVIDER-CORE.md).

## Try the native prototype

```sh
scripts/native-prototype.sh run
scripts/native-prototype.sh test
```

Requires macOS and the Xcode Swift 6 toolchain. Deployment target: macOS 14+;
runtime verification so far: macOS 26.5.1 on Apple Silicon, Xcode 26.6.
Builds are locally ad-hoc signed, not notarized release binaries. No API key or
third-party dependency installation is needed for the current app or tests.

## What works

| Area | Current status |
|---|---|
| Native UI | Three-pane workspace, bot/group creation, search, hide/show, native text composer |
| Local data | Core Data persistence, drafts, message pagination, paused routine records |
| Provider integration | Native Settings, endpoint/model selection, attributed streamed text, queue, Stop/Retry; offline-fixture tested |
| Credentials | Protected Keychain by default, explicit session-only memory option; no automatic fallback; authorized signing/Keychain access still unverified |
| Remaining gates | Live-provider validation, routine execution, attachments/export, remaining edit/delete and native accessibility flows |

Verification: **125 tests** (71 core + 54 shell), desktop/narrow native persistence
and offline provider smokes, Settings rendering, build/signature and formatting checks. See the evidence
and limitations below for the current test counts and scope.

## Architecture and contracts

```text
SwiftUI + AppKit → presentation adapter → WorkspaceRepository → Core Data

Native provider settings + composer → GenerationCoordinator
  → CredentialStore + ChatProvider → URLSession / SSE
```

- [Product and acceptance contract](docs/NATIVE-REWRITE-CONTRACT.md)
- [Durable workspace and verification](docs/DURABLE-WORKSPACE.md)
- [Provider core and verification gaps](docs/PROVIDER-CORE.md)
- [Native prototype, pages and layout](docs/NATIVE-PROTOTYPE.md)
- [Product scope](PRODUCT.md) · [Design](DESIGN.md) · [Contributing](CONTRIBUTING.md)

## License and provenance

[MIT](LICENSE) for this project's original code and documentation. Third-party
names and marks are not licensed by this project. Private third-party reference
screenshots, extracted app bundles, credentials, workspace data and agent runtime
state are excluded from the public source. The app draws its own interface and
geometric avatars; no reference image is required to build or run it.
