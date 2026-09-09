# Durable native workspace — implementation checkpoint

2026-09-10. This advances the [native rewrite contract](NATIVE-REWRITE-CONTRACT.md); it is **not full-app completion**. Native shell source still lives under `Prototypes/NativeShell` while it is being promoted into the app. Persistence code is independent in `Packages/WorkspaceCore`.

## Run

```sh
scripts/native-app.sh run       # build/sign/open BotWorkspace.app
scripts/native-app.sh test      # repository + native shell tests
scripts/native-app.sh smoke     # isolated on-disk workspace; native render and process exit
scripts/native-app.sh smoke --small
scripts/native-app.sh profile-smoke              # bot/group edits, close/reopen, bot sheet
scripts/native-app.sh profile-smoke --edit-group # render the group sheet instead
scripts/native-app.sh reply-smoke               # restore a reply draft and send through a fixture
scripts/native-app.sh routine-smoke             # daily editor, offline run, pause/resume, history
```

Build artifact: `Prototypes/NativeShell/.build/BotWorkspace.app`. Bundle ID: `local.independent.BotWorkspace` (working identifier, not final distribution identity). Double-clicking this bundle opens durable mode. The separate `NativeShellPrototype.app` remains sample-only.

Data is created under the app sandbox's Application Support `BotWorkspace/workspace.sqlite`. No sample bots/messages are inserted in the real workspace; use **+ → Create Bot** or a local template. The computer service remains disconnected. Native routine scheduling is opt-in, only while the app is open and the Mac is awake. The AI provider path is connected to native settings/chat and verified with offline fixtures; live provider and Keychain/signing checks remain open. New routines are paused unless explicitly enabled with provider/owner consent. Sending without a provider preserves the editable, persisted draft and creates no fake reply.

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
- `CoreDataWorkspaceRepository.swift`: normalized entity records with versioned Codable payloads; indexed conversation/sequence message access; atomic save/rollback; immutable v1/v2 models and explicit v3 migration; corruption/incompatibility rejection; cross-process lease.
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
| Save draft | Native conversation-scoped Unicode text/reply selection, cancellation and original-message navigation; persisted on debounce/flush; native selected text files use atomic managed copies and persistent removable chips; invalid references are rejected |
| Begin generation | User message, queued generation/attempt, monotonically assigned sequence and matching-draft clear are atomic; newer draft text is preserved |
| Cancel/reconcile | Stale attempt cannot cancel current work; restart reconciliation marks pending work interrupted without replaying it |
| Routines | Native interval/daily editor with explicit owner/provider consent; Run Now, pause/resume, Stop, confirmed deletion, visible history, awake reconciliation. No work is promised while closed/asleep |
| Save provider | Metadata/reference only; reject URL userinfo/query/fragment, non-HTTPS except explicitly opted-in loopback; native settings/credential entry/send are wired; **real signing/Keychain and broad provider verification remain open; a minimal native Codex reply has passed** |
| Message page | Latest 100 by default, limits 1–500; exclusive sequence cursor; older page stable when newer messages arrive |
| Search | Case/diacritic-insensitive title/message search, with hidden conversations excluded by default |
| Export | One-revision, all-history JSON including exact referenced attachment payloads with explicit provider allowlist; native save dialog, draft flush and single-flight failure handling. No credential reads or import; see [format/privacy limits](WORKSPACE-EXPORT.md) |
| Delete bot | Explicit impact confirmation, scoped cancel/join, atomic direct-record/routine deletion; shared providers and group history kept; 0/1-member groups require repair. See [deletion contract](BOT-DELETION.md) |
| Open/close | One owner per canonical store path; incompatible/corrupt store errors preserve bytes, never reset to sample data |

No managed object, API secret, HTTP request, shell command, or cloud-computer capability is exposed through the repository. Provider metadata validation does not prove compatibility with a real endpoint.

The [routine flow](ROUTINES.md), introduced in schema v2, is preserved by schema v3 with tested migration/recovery, native interval/daily editing, explicit transmission consent, run controls/history, and launch/wake/awake-timer scheduling. Previously paused routines are not silently enabled.

## Verification evidence

Host: macOS 26.5.1 / Apple Silicon, Xcode 26.6, Swift 6.3.3.

- **234 core tests**: actual SQLite restart/migration/recovery, atomic writes, identity/CAS checks,
  generation/coordinator, provider/transport, model catalog, Codex, profiles, reply context,
  export/deletion, calendar boundaries and routine claims/lifecycle. Attachment coverage adds
  13 content/repository tests, 5 historical migration/recovery tests, 13 generation-consent and 3 wire/fingerprint
  tests and legacy export-summary decoding. All use offline credentials,
  URLProtocol/provider fixtures and/or actual temporary stores.
- **226 native shell tests**: fixture/AppKit/persistence, provider presentation and Codex setup,
  profiles/replies/export/deletion, **11 routine editor** tests and **14 routine workspace/lifecycle**
  tests, plus 5 attachment presentation, 16 file importer and 18 workflow tests. Appearance adds 8 preference-storage, 9 workspace/layout and 5 theme/composer tests. Total: **460 tests**.
  Routine coverage includes explicit owner/binding consent, provider
  drift, dirty/cancel/reload/save races, catch-up/wake, direct-chat output, draft preservation,
  Stop/partial text, confirmed deletion, active history after clock rollback, and quit joining.

- Native `smoke` uses a newly minted temporary workspace inside this app's sandbox, creates two bots/one group/one paused routine/a Unicode draft through the UI's service path, closes/reopens the store, asserts restored identities/content, renders the native window, removes only its own test directory and exits. It does not open, mutate, or capture the user's normal workspace.
- Provider smoke injects offline credentials and a fixture stream into that isolated native workspace, verifies persisted user/assistant messages and attribution, and renders desktop/narrow chat and the separate Settings window. No live endpoint or real Keychain item is accessed.
- Appearance smoke switches Dark/Light/System using an isolated preference suite, renders workspace and Settings, preserves saved widths and draft/message state, and checks the 760×600 minimum variant. Physical input/system-theme switching remain manual; see [appearance evidence](APPEARANCE.md).
- Attachment smoke copies a synthetic selected text file, deletes its original, reopens the managed copy, renders chips/consent, verifies Cancel has no credential/provider calls and confirms an exact offline file send. OS panel clicks and external grants remain manual. See [attachment contract](ATTACHMENTS.md).
- Reply smoke restores a selected parent/text after SQLite reopen, checks explicit context at the fixture provider boundary, sends/persists the reference, clears only the matching draft, then renders an unsent follow-up. See [reply workflow](REPLY-WORKFLOW.md).
- Export smoke writes/replaces a synthetic JSON file in its own sandbox temporary directory, checks complete fixture records/draft flush/credential-reference exclusion and renders Settings. It injects the destination; native Save Panel interaction and its external sandbox grant remain unautomated. See [export format and limits](WORKSPACE-EXPORT.md).
- Routine smoke renders the native daily editor and history, executes an offline run into the explicit owner’s direct chat, keeps the group draft, resumes/pauses and reopens. It uses synthetic fixtures and controller actions, not physical input automation. See [routine verification limits](ROUTINES.md).
- Deletion smoke renders the confirmation, invokes the same native controller action, reopens the synthetic workspace and verifies removed bot/direct/routine records plus preserved group history/provider and repair state. It does not exercise physical menu/button input or user data. See [deletion verification limits](BOT-DELETION.md).
- Profile smoke edits one bot and one group's ordered membership through the native controller, closes and reopens the isolated store, verifies stable identities plus preserved drafts/routines, and renders either editor sheet. It performs no provider request.
- A separate user-authorized native Codex stdin check completed a minimal real reply and verified its persisted attribution/draft clearing in an isolated workspace, without modifying or refreshing the original auth file. This is one account/time, not broad provider/9router/Keychain or release verification. Normal offline tests do not require credentials.
- The profile sheet explicitly allows AppKit to consult the application delegate during termination. Save ownership is claimed synchronously, and quit joins the controller before rechecking any newer unsaved fields. A clean attached-sheet smoke now exits successfully; dirty-alert/IME/VoiceOver end-to-end interaction remains an open manual gate.
- Smoke initially exposed a MainActor/AppKit `terminateLater` nested-loop hang. The quit path now cancels the initial request, asynchronously flushes/closes, and issues prepared termination; the corrected smoke process exits successfully.
- Swift build/typecheck, strict Swift-format lint, shell syntax checks, local ad-hoc code-signature verification and whitespace checks pass. The durable app has App Sandbox, outgoing network client and user-selected read-write file entitlements for explicit import/export; the sample bundle has only App Sandbox. No broad-file-access or invented Keychain access-group entitlement is added.

## Explicit remaining gates

- A Core Data **close/reopen** test is not a process-kill/power-loss test. Explicit v1/v2→v3 migration and injected replacement/recovery failures are covered with synthetic historical stores; logical payload preservation does not certify arbitrary I/O failure, fsync/power loss, or byte-identical SQLite/WAL layouts.
- T08 injects a failure at the transaction save boundary. This proves rollback and draft retention; a coordinator fake also verifies zero provider calls after a failed save. Neither is a real disk-full OS test.
- Message rows are paginated, but snapshot generation history is not yet bounded. T13's persisted 10k-message native rendering/50 updates/sec/Instruments budget remains **unverified**.
- Actual IME candidate input, full VoiceOver/focus/shortcuts/divider interaction, and macOS 14 runtime coverage remain open.
- Real attachment file-picker sandbox grants, real provider/Keychain signing verification, physical routine sleep/wake checks, complete profile/settings/delete/routine a11y interaction, XCUITest coverage, and release signing/notarization are incomplete. Native bot/group profile editing and confirmed bot deletion have unit, persistence, concurrency and smoke coverage, but this does not close every R02/UI acceptance gate.

The full R01–R09 / T01–T18 contract stays active. This durable offline milestone is progress toward it, not a smaller replacement finish line.
