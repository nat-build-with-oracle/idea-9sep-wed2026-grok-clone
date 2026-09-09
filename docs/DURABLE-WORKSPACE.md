# Durable native workspace — implementation checkpoint

2026-09-09. This advances the [native rewrite contract](NATIVE-REWRITE-CONTRACT.md); it is **not full-app completion**. Native shell source still lives under `Prototypes/NativeShell` while it is being promoted into the app. Persistence code is independent in `Packages/WorkspaceCore`.

## Run

```sh
scripts/native-app.sh run       # build/sign/open BotWorkspace.app
scripts/native-app.sh test      # repository + native shell tests
scripts/native-app.sh smoke     # isolated on-disk workspace; native render and process exit
scripts/native-app.sh smoke --small
```

Build artifact: `Prototypes/NativeShell/.build/BotWorkspace.app`. Bundle ID: `local.independent.BotWorkspace` (working identifier, not final distribution identity). Double-clicking this bundle opens durable mode. The separate `NativeShellPrototype.app` remains sample-only.

Data is created under the app sandbox's Application Support `BotWorkspace/workspace.sqlite`. No sample bots/messages are inserted in the real workspace; use **+ → Create Bot** or a local template. The scheduler and computer service remain disconnected. The AI provider path is connected to native settings/chat and verified with offline fixtures; live provider and Keychain/signing checks remain open. Routines are saved paused. Sending without a provider preserves the editable, persisted draft and creates no fake reply.

## Architecture and ownership

```text
SwiftUI/AppKit views
  → MainActor presentation projection (PersistentWorkspace.swift)
    → WorkspaceRepository (Sendable value-type interface)
      → one Core Data private-queue context
        → transaction / revision / unique identities
          → app-managed SQLite + process-exclusive lease

UI draft edit → in-memory text → 300 ms debounce → saveDraft
                                 switch/deactivate/quit → flush
write failure → retain dirty draft + visible error; quit is cancelled

configured native send → persist user message + queued generation + sequence
                            → commit succeeds → coordinator may start transport
                            → commit fails    → rollback; no transport call
```

The repository confines managed objects to its private queue; only Codable/Sendable domain values cross the boundary, following [Apple's Core Data concurrency guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/Concurrency.html). It uses Core Data's own SQLite store APIs, not direct SQL against Core Data's private format, consistent with [Apple's persistent-store guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html).

### Files

- `Packages/WorkspaceCore/Sources/WorkspaceCore/Domain.swift`: stable UUID DTOs; bot/group/draft/message/generation/routine/provider fields and validation.
- `WorkspaceRepository.swift`: typed mutations, explicit revision precondition and paginated-message contract.
- `CoreDataWorkspaceRepository.swift`: normalized entity records with versioned Codable payloads; indexed conversation/sequence message access; atomic save/rollback; v1 model; corruption/incompatibility rejection; cross-process lease.
- `GenerationCoordinator.swift`, `ChatProvider.swift`, `ChatCompletionsProvider.swift`, `CredentialStore.swift`: provider and generation core, connected through `ProviderWorkspace.swift` and `ProviderSettingsView.swift`. See [provider checkpoint](PROVIDER-CORE.md) for tested scope and Keychain/live-network gaps.
- `Prototypes/NativeShell/Sources/NativeShell/PersistentWorkspace.swift`: UI projection and awaited mutations, debounced drafts, storage-error state, search and paged transcript reads.
- `NativeShellApp.swift`: sandbox store startup, retry-open action, deactivate/quit flushing, and isolated native smoke fixture.
- `scripts/native-app.sh`, `scripts/native-prototype.sh`: two separately identified local bundles from one shell executable. No third-party dependencies or localhost server.

## Function and data contracts implemented

| Operation | Implemented invariant |
|---|---|
| Create bot | Bot and direct conversation commit together with different stable IDs; trimmed name, description/color and provider references validated |
| Edit/hide bot | Repository edit updates direct title; hide is reversible and keeps routines; UI exposes hide/unhide, **edit UI is still missing** |
| Create/update group | Ordered 2–6 unique existing members; hidden members rejected when added; UI exposes create, **membership edit UI is still missing** |
| Save draft | Conversation-scoped Unicode text/reply; persisted on explicit flush; unsupported attachment references are rejected rather than dropped |
| Begin generation | User message, queued generation/attempt, monotonically assigned sequence and matching-draft clear are atomic; newer draft text is preserved |
| Cancel/reconcile | Stale attempt cannot cancel current work; restart reconciliation marks pending work interrupted without replaying it |
| Save routine | Explicit bot owner, valid interval/daily time, time zone, nonempty prompt; **UI currently offers paused intervals only**, no execution |
| Save provider | Metadata/reference only; reject URL userinfo/query/fragment, non-HTTPS except explicitly opted-in loopback; native settings/credential entry/send are wired; **real signing/Keychain and live-provider verification remain open** |
| Message page | Latest 100 by default, limits 1–500; exclusive sequence cursor; older page stable when newer messages arrive |
| Search | Case/diacritic-insensitive title/message search, with hidden conversations excluded by default |
| Open/close | One owner per canonical store path; incompatible/corrupt store errors preserve bytes, never reset to sample data |

No managed object, API secret, HTTP request, shell command, or cloud-computer capability is exposed through the repository. Provider metadata validation does not prove compatibility with a real endpoint.

## Verification evidence

Host: macOS 26.5.1 / Apple Silicon, Xcode 26.6, Swift 6.3.3.

- **29 repository tests**, including actual SQLite close/reopen, bot edits/hiding, ordered group membership, Unicode drafts, save failure rollback, concurrent sequence allocation, duplicate IDs, keyset pages, stale revision/attempt rejection, corrupted/incompatible store byte preservation, and exclusive lease behavior.
- **34 additional core tests**: 11 generation/coordinator, 15 SSE parser and 8 transport/request tests. Together with the repository tests, the core suite has **63 tests**. These use offline providers/credentials and URLProtocol, not live accounts.
- **37 shell tests**: 26 fixture/policy tests, 5 deterministic AppKit editor/lifecycle tests, 6 durable presentation-adapter tests. These include synthetic public-release fixtures, disabled-editor behavior during closing and a continuation-gated draft edit arriving while a prior save is suspended. The adapter tests use real temporary SQLite stores and one injected failing repository. The 13 provider-presentation tests add credential/metadata rollback, attributed sends, group targeting, draft races, Stop/Retry and failed-shutdown recovery. Total: **113 tests** (63 core + 50 shell).
- Native `smoke` uses a newly minted temporary workspace inside this app's sandbox, creates two bots/one group/one paused routine/a Unicode draft through the UI's service path, closes/reopens the store, asserts restored identities/content, renders the native window, removes only its own test directory and exits. It does not open, mutate, or capture the user's normal workspace.
- Provider smoke injects offline credentials and a fixture stream into that isolated native workspace, verifies persisted user/assistant messages and attribution, and renders desktop/narrow chat and the separate Settings window. No live endpoint or real Keychain item is accessed.
- Smoke initially exposed a MainActor/AppKit `terminateLater` nested-loop hang. The quit path now cancels the initial request, asynchronously flushes/closes, and issues prepared termination; the corrected smoke process exits successfully.
- Swift build/typecheck, strict Swift-format lint, shell syntax checks, local ad-hoc code-signature verification and whitespace checks pass. The durable app has App Sandbox and outgoing network client entitlements; the sample bundle has only App Sandbox. No broad-file-access or invented Keychain access-group entitlement is added.

## Explicit remaining gates

- A Core Data **close/reopen** test is not a process-kill/power-loss test. New v1 stores and incompatible-model rejection are covered; no historical schema migration exists yet. Never claim a tested upgrade migration without adding its fixtures.
- T08 injects a failure at the transaction save boundary. This proves rollback and draft retention; a coordinator fake also verifies zero provider calls after a failed save. Neither is a real disk-full OS test.
- Message rows are paginated, but snapshot generation history is not yet bounded. T13's persisted 10k-message native rendering/50 updates/sec/Instruments budget remains **unverified**.
- Actual IME candidate input, full VoiceOver/focus/shortcuts/divider interaction, and macOS 14 runtime coverage remain open.
- Production bot/group edit and confirmed delete UI, reply/attachment/export flows, real provider/Keychain signing verification, routine execution/history/DST lifecycle, complete settings/a11y interaction, and release signing/notarization are incomplete. Native provider settings, SSE/Stop/Retry integration and a separate Settings window now have offline fixture evidence.

The full R01–R09 / T01–T18 contract stays active. This durable offline milestone is progress toward it, not a smaller replacement finish line.
