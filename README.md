# BotWorkspace

An independent, open-source native macOS workspace for named AI teammates.
Built with **SwiftUI, AppKit and Core Data**, using only Apple frameworks.
The repository name preserves its original [grok-clone idea capsule](PROPOSAL.md).

**Experimental source release, not a finished AI client.** Bots, groups, drafts
and routines persist locally. Native provider settings, streamed replies,
explicit group targeting, Stop and Retry are wired to the provider core and tested
with offline fixtures. An experimental, fixed-origin Codex text adapter accepts an explicitly imported
ChatGPT `auth.json` for this session only. Real Keychain/signing and broad provider
compatibility remain open. No Grok Bot/Cursor service, subscription,
remote computer or private API is included; this project is not affiliated with them.

## Run the local app

```sh
scripts/native-app.sh run
scripts/native-app.sh test
scripts/native-app.sh smoke
scripts/native-app.sh provider-smoke # offline fixture; no key or live network
scripts/native-app.sh codex-smoke    # synthetic auth + intercepted Responses SSE
scripts/native-app.sh profile-smoke  # bot edit + group edit + close/reopen
scripts/native-app.sh appearance-smoke # isolated Dark/Light/System + persistent pane preferences
scripts/native-app.sh attachment-smoke # synthetic selected files + consent + offline send
scripts/native-app.sh reply-smoke    # reply draft restart + referenced fixture send
scripts/native-app.sh export-smoke   # JSON export + atomic file replacement (text fixture)
scripts/native-app.sh deletion-smoke # confirmed bot deletion + retained group/restart
scripts/native-app.sh routine-smoke  # daily editor + offline run + pause/resume/history restart
```

The `.app` is built at `Prototypes/NativeShell/.build/BotWorkspace.app`. It opens an empty workspace on first use and keeps data inside its macOS sandbox. **No provider is configured by default.** Settings offers Z.ai general API, local 9router, OpenAI Platform and custom setup templates. A separate **Codex login (experimental)** provider type imports a user-selected auth JSON into memory only; it is not an OpenAI Platform API key. Enter the endpoint/model/key for compatible providers, then select the provider and (for groups) the replying bot in the composer. Without a usable credential, the draft is retained.

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
| Appearance/layout | Saved Dark/Light/System, Save/Cancel settings, persistent pane widths/visibility, minimum-width chat protection |
| Native UI | Three-pane workspace, bot/group creation and profile editing, search, hide/show, confirmed bot deletion/group repair, native text composer, message replies |
| Local data | Core Data v3 with tested v1/v2 migration, text/reply drafts, message pagination, routine ledger, JSON export v3 including stored attachment bytes |
| Provider integration | Native Settings, endpoint/model selection, attributed streamed text, queue, Stop/Retry; offline-fixture tested |
| Credentials | API keys: protected Keychain or explicit session memory. Codex login: explicit file import, memory-only, fixed host, no refresh. Authorized signing/Keychain still unverified |
| Routines | Native interval/daily editor, explicit owner/provider consent, Run Now, pause/resume, Stop/delete and history; launch/wake/30-second awake scheduling, offline tested |
| Text attachments | Native file picker, persistent/removable chips, atomic managed copies and per-send file/destination confirmation; no images |
| Remaining gates | Broad provider/9router validation, real file-picker sandbox grants and remaining native accessibility flows |

Verification: **460 tests** (234 core + 226 shell), desktop/narrow native persistence,
offline provider smokes, profile-edit and reply close/reopen smokes, attachment storage/migration, importer and explicit-consent guards, text-fixture export, confirmed deletion and routine editor/run/restart smokes, appearance/pane preference tests and light/dark minimum-window rendering, Settings rendering, build/signature and formatting checks. See [reply workflow](docs/REPLY-WORKFLOW.md) and the evidence
and limitations below for the current test counts and scope. An explicitly authorized
manual native Codex check also completed a minimal reply with persistence and
attribution; one account/time is not broad compatibility or release certification.

## Architecture and contracts

```text
SwiftUI + AppKit → presentation adapter → WorkspaceRepository → Core Data

Native provider settings + composer → GenerationCoordinator
  → CredentialStore + ChatProvider → URLSession / SSE
```

- [Product and acceptance contract](docs/NATIVE-REWRITE-CONTRACT.md)
- [Durable workspace and verification](docs/DURABLE-WORKSPACE.md)
- [Appearance and layout preferences](docs/APPEARANCE.md)
- [Native attachment workflow and storage decision](docs/ATTACHMENTS.md)
- [Workspace export format and privacy limits](docs/WORKSPACE-EXPORT.md)
- [Confirmed bot deletion and group repair](docs/BOT-DELETION.md)
- [Routine execution, native controls and scheduling limits](docs/ROUTINES.md)
- [Provider core and verification gaps](docs/PROVIDER-CORE.md)
- [Experimental Codex adapter contract](docs/CODEX-ADAPTER-CONTRACT.md)
- [Native prototype, pages and layout](docs/NATIVE-PROTOTYPE.md)
- [Product scope](PRODUCT.md) · [Design](DESIGN.md) · [Contributing](CONTRIBUTING.md)

## License and provenance

[MIT](LICENSE) for this project's original code and documentation. Third-party
names and marks are not licensed by this project. Private third-party reference
screenshots, extracted app bundles, credentials, workspace data and agent runtime
state are excluded from the public source. The app draws its own interface and
geometric avatars; no reference image is required to build or run it.
