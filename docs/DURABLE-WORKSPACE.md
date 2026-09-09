# Durable native workspace — implementation checkpoint

2026-09-09. This advances the [native rewrite contract](NATIVE-REWRITE-CONTRACT.md); it is **not full-app completion**. Native shell source still lives under `Prototypes/NativeShell` while it is being promoted into the app. Persistence code is independent in `Packages/WorkspaceCore`.

## Run

```sh
scripts/native-app.sh run       # build/sign/open BotWorkspace.app
scripts/native-app.sh test      # repository + native shell tests
scripts/native-app.sh smoke     # isolated on-disk workspace; native render and process exit
scripts/native-app.sh smoke --small
scripts/native-app.sh profile-smoke              # bot/group edits, close/reopen, bot sheet
scripts/native-app.sh profile-smoke --edit-group # render the group sheet instead
scripts/native-app.sh reply-smoke               # restore a reply draft and send through a fixture
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

profile sheet → detached editable snapshot → validated atomic edit
                 stale editable fields → reject save + offer explicit reload
                 Cancel/Escape/close → confirm before discarding dirty fields

configured native send → persist user message + queued generation + sequence
                            → commit succeeds → coordinator may start transport
                            → commit fails    → rollback; no transport call
```

The repository confines managed objects to its private queue; only Codable/Sendable domain values cross the boundary, following [Apple's Core Data concurrency guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/Concurrency.html). It uses Core Data's own SQLite store APIs, not direct SQL against Core Data's private format, consistent with [Apple's persistent-store guidance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreData/PersistentStoreFeatures.html).

### Files

- `Packages/WorkspaceCore/Sources/WorkspaceCore/Domain.swift`, `ProfileEditing.swift`: stable UUID DTOs plus validated, editable-only bot and group profile snapshots.
- `WorkspaceRepository.swift`: typed mutations, explicit revision precondition and paginated-message contract.
- `CoreDataWorkspaceRepository.swift`: normalized entity records with versioned Codable payloads; indexed conversation/sequence message access; atomic save/rollback; v1 model; corruption/incompatibility rejection; cross-process lease.
- `GenerationCoordinator.swift`, `ChatProvider.swift`, `ChatCompletionsProvider.swift`, `CredentialStore.swift`: provider and generation core, connected through `ProviderWorkspace.swift` and `ProviderSettingsView.swift`. See [provider checkpoint](PROVIDER-CORE.md) for tested scope and Keychain/live-network gaps.
- `Prototypes/NativeShell/Sources/NativeShell/PersistentWorkspace.swift`, `EditingWorkspace.swift`: UI projection and awaited mutations, debounced drafts, profile-edit snapshots, storage-error state, search and paged transcript reads.
- `ProfileEditorView.swift`: native bot fields and ordered group membership editing, dirty-discard/reload confirmation, and stable-target controller state.
- `NativeShellApp.swift`: sandbox store startup, retry-open action, deactivate/quit flushing, and isolated native smoke fixture.
- `scripts/native-app.sh`, `scripts/native-prototype.sh`: two separately identified local bundles from one shell executable. No third-party dependencies or localhost server.

## Function and data contracts implemented

| Operation | Implemented invariant |
|---|---|
| Create bot | Bot and direct conversation commit together with different stable IDs; trimmed name, description/color and provider references validated |
| Edit/hide bot | Native editor changes name, description, color and shape; direct title follows the normalized name. Identity, creation date, provider assignment, visibility, routines, drafts and transcript remain intact; hide/unhide stays separate |
| Create/update group | Native editor changes the title and ordered 2–6-member list. Existing hidden members may remain, but hidden/missing bots cannot be newly added; future target choices follow the new list without rewriting an in-flight reply or recorded attribution |
| Save draft | Native conversation-scoped Unicode text/reply selection, cancellation and original-message navigation; persisted on debounce/flush; unsupported attachment references are rejected rather than dropped |
| Begin generation | User message, queued generation/attempt, monotonically assigned sequence and matching-draft clear are atomic; newer draft text is preserved |
| Cancel/reconcile | Stale attempt cannot cancel current work; restart reconciliation marks pending work interrupted without replaying it |
| Save routine | Explicit bot owner, valid interval/daily time, time zone, nonempty prompt; **UI currently offers paused intervals only**, no execution |
| Save provider | Metadata/reference only; reject URL userinfo/query/fragment, non-HTTPS except explicitly opted-in loopback; native settings/credential entry/send are wired; **real signing/Keychain and broad provider verification remain open; a minimal native Codex reply has passed** |
| Message page | Latest 100 by default, limits 1–500; exclusive sequence cursor; older page stable when newer messages arrive |
| Search | Case/diacritic-insensitive title/message search, with hidden conversations excluded by default |
| Export | One-revision, all-history text-only JSON with explicit provider allowlist; native save dialog, draft flush and single-flight failure handling. No credential reads or import; see [format/privacy limits](WORKSPACE-EXPORT.md) |
| Open/close | One owner per canonical store path; incompatible/corrupt store errors preserve bytes, never reset to sample data |

No managed object, API secret, HTTP request, shell command, or cloud-computer capability is exposed through the repository. Provider metadata validation does not prove compatibility with a real endpoint.

## Verification evidence

Host: macOS 26.5.1 / Apple Silicon, Xcode 26.6, Swift 6.3.3.

- **29 repository tests**, including actual SQLite close/reopen, bot edits/hiding, ordered group membership, Unicode drafts, save failure rollback, concurrent sequence allocation, duplicate IDs, keyset pages, stale revision/attempt rejection, corrupted/incompatible store byte preservation, and exclusive lease behavior.
- **108 additional core tests**: generation/coordinator, provider/transport, model-catalog, Codex, 9 profile-editing tests, 8 reply-context tests, and 5 export tests. Profile coverage includes editable-only conflict checks, rollback, ordered/hidden membership rules, close/reopen identity and sequence preservation, and in-flight attribution. Core total: **137**, using offline credentials/URLProtocol and actual temporary stores.
- **126 shell tests**: fixture/AppKit/persistence, provider presentation, model discovery, Codex settings/flow, 16 profile editor/workspace tests, 17 reply presentation/workspace tests, and 23 export lifecycle/file-writer tests. Profile coverage includes validation, dirty Cancel/reload, late-load and in-flight-save races, stable edit targets, close/reopen persistence, and quit waiting for an active save. Total: **263 tests**.

- Native `smoke` uses a newly minted temporary workspace inside this app's sandbox, creates two bots/one group/one paused routine/a Unicode draft through the UI's service path, closes/reopens the store, asserts restored identities/content, renders the native window, removes only its own test directory and exits. It does not open, mutate, or capture the user's normal workspace.
- Provider smoke injects offline credentials and a fixture stream into that isolated native workspace, verifies persisted user/assistant messages and attribution, and renders desktop/narrow chat and the separate Settings window. No live endpoint or real Keychain item is accessed.
- Reply smoke restores a selected parent/text after SQLite reopen, checks explicit context at the fixture provider boundary, sends/persists the reference, clears only the matching draft, then renders an unsent follow-up. See [reply workflow](REPLY-WORKFLOW.md).
- Export smoke writes/replaces a synthetic JSON file in its own sandbox temporary directory, checks complete fixture records/draft flush/credential-reference exclusion and renders Settings. It injects the destination; native Save Panel interaction and its external sandbox grant remain unautomated. See [export format and limits](WORKSPACE-EXPORT.md).
- Profile smoke edits one bot and one group's ordered membership through the native controller, closes and reopens the isolated store, verifies stable identities plus preserved drafts/routines, and renders either editor sheet. It performs no provider request.
- A separate user-authorized native Codex stdin check completed a minimal real reply and verified its persisted attribution/draft clearing in an isolated workspace, without modifying or refreshing the original auth file. This is one account/time, not broad provider/9router/Keychain or release verification. Normal offline tests do not require credentials.
- The profile sheet explicitly allows AppKit to consult the application delegate during termination. Save ownership is claimed synchronously, and quit joins the controller before rechecking any newer unsaved fields. A clean attached-sheet smoke now exits successfully; dirty-alert/IME/VoiceOver end-to-end interaction remains an open manual gate.
- Smoke initially exposed a MainActor/AppKit `terminateLater` nested-loop hang. The quit path now cancels the initial request, asynchronously flushes/closes, and issues prepared termination; the corrected smoke process exits successfully.
- Swift build/typecheck, strict Swift-format lint, shell syntax checks, local ad-hoc code-signature verification and whitespace checks pass. The durable app has App Sandbox, outgoing network client and user-selected read-write file entitlements for explicit import/export; the sample bundle has only App Sandbox. No broad-file-access or invented Keychain access-group entitlement is added.

## Explicit remaining gates

- A Core Data **close/reopen** test is not a process-kill/power-loss test. New v1 stores and incompatible-model rejection are covered; no historical schema migration exists yet. Never claim a tested upgrade migration without adding its fixtures.
- T08 injects a failure at the transaction save boundary. This proves rollback and draft retention; a coordinator fake also verifies zero provider calls after a failed save. Neither is a real disk-full OS test.
- Message rows are paginated, but snapshot generation history is not yet bounded. T13's persisted 10k-message native rendering/50 updates/sec/Instruments budget remains **unverified**.
- Actual IME candidate input, full VoiceOver/focus/shortcuts/divider interaction, and macOS 14 runtime coverage remain open.
- Confirmed delete UI, attachment packaging/import flows, real provider/Keychain signing verification, routine execution/history/DST lifecycle, complete profile/settings a11y interaction, XCUITest coverage, and release signing/notarization are incomplete. Native bot/group profile editing has unit, persistence, concurrency and smoke coverage, but this does not close every R02/UI acceptance gate.

The full R01–R09 / T01–T18 contract stays active. This durable offline milestone is progress toward it, not a smaller replacement finish line.
