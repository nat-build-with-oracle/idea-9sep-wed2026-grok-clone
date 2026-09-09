# BotWorkspace

An independent, open-source native macOS workspace for named AI teammates.
Built with **SwiftUI, AppKit and Core Data**, using only Apple frameworks.
The repository name preserves its original [grok-clone idea capsule](PROPOSAL.md).

**Experimental source release, not a finished AI client.** Bots, groups, drafts
and paused routines persist locally. A tested provider/streaming core exists, but
it is **not connected to the app UI yet**. No Grok Bot/Cursor service, subscription,
remote computer or private API is included; this project is not affiliated with them.

## Run the local app

```sh
scripts/native-app.sh run
scripts/native-app.sh test
scripts/native-app.sh smoke
```

The `.app` is built at `Prototypes/NativeShell/.build/BotWorkspace.app`. It opens an empty workspace on first use and keeps data inside its macOS sandbox. **No AI provider is connected yet:** Send preserves your locally saved draft rather than pretending to send a message. See [durable workspace implementation and evidence](docs/DURABLE-WORKSPACE.md).

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
| Provider core | URLSession/SSE transport, generation queue, cancellation/retry; fixture-tested, not UI-integrated |
| Credentials | Keychain adapter source exists; real Keychain/signing behavior is not verified |
| Not yet implemented end-to-end | Live model replies, routine execution, attachments/export, remaining edit/delete flows |

Verification: **99 tests** (62 core + 37 shell), desktop/narrow native persistence
smokes, build/signature and formatting checks. See the evidence and limitations below.

## Architecture and contracts

```text
SwiftUI + AppKit → presentation adapter → WorkspaceRepository → Core Data

Provider core (not wired to UI):
GenerationCoordinator → CredentialStore + ChatProvider → URLSession / SSE
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
