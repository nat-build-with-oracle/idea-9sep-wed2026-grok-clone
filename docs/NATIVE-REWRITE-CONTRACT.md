# Native rewrite: product and engineering contract

Status: **production contract in progress; native shell and durable local workspace available** · 2026-09-09

This supersedes the browser-first sketch. It is not authorization to connect to private Grok Bot endpoints or operate the user's computer. The goal remains an original app based on the supplied reference, not a screenshot pasted into a wrapper.

## 1. Decision and evidence

**Recommend SwiftUI + targeted AppKit for a macOS-first v1.** Choose Tauri 2 instead if Windows/Linux delivery is a first-release requirement. That product priority is the remaining material platform decision; it has been asked, not assumed confirmed.

Decision drivers, in order:
1. Native macOS input, windows, menus, accessibility, and lifecycle behavior.
2. Fidelity to the supplied messaging UI without reproducing private service dependencies.
3. A testable domain/persistence/provider boundary, independent of rendering.

Current repository evidence:
- `PROPOSAL.md` is an idea capsule, not an implemented product specification.
- `PRODUCT.md` records the native planning change and the lack of supplied backend credentials.
- `DESIGN.md` records the three-pane reference and proposed dimensions.
- The supplied image is preserved unchanged locally, with SHA-256 matching the original attachment. This third-party design reference is intentionally excluded from the public repository and is not an app/test dependency.
- Local inspection found macOS 26.5.1 / arm64, Xcode 26.6, Swift 6.3.3, selected Xcode developer directory. Rust/Cargo were not found on PATH; this is a setup cost, not evidence Tauri is impossible.
- No proprietary app source was imported. `Packages/WorkspaceCore` now implements the durable repository; the native shell remains under `Prototypes/NativeShell` with separate sample/durable bundles. Other section 10 paths remain planned.
- The [sample verification record](NATIVE-PROTOTYPE.md) and [durable workspace evidence](DURABLE-WORKSPACE.md) are bounded milestone evidence, not fulfillment of all requirements below or confirmation of the open cross-platform decision.

### Option comparison

| Concern | SwiftUI + AppKit | Tauri 2 + web UI |
|---|---|---|
| Actual UI | Native view hierarchy, selective AppKit bridges | System WebView UI with Rust host; desktop-native shell, not native controls throughout |
| Screenshot fidelity | Custom SwiftUI layout/shapes; bridge editor when needed | CSS offers direct layout matching, but native input/window behavior still needs deliberate work |
| macOS integration | Platform APIs directly | Native integration through Rust commands/plugins or platform-specific bridges |
| Cross-platform | Separate Windows/Linux implementation | Shared web UI, with platform packaging/testing still required |
| Toolchain here | Xcode and Swift available | Rust/Cargo setup required; web build toolchain also selected |
| Trust boundary | Swift domain services → OS/provider APIs | WebView → narrowly scoped Tauri commands/capabilities → OS/provider APIs |
| Dependency posture | Apple frameworks; no third-party requirement | Tauri/Rust/web dependencies are an explicit adoption decision |

Do not claim either option is inherently faster, smaller, or safer without measuring the actual build. SwiftUI does not mean all views must be pure SwiftUI. Tauri does not remove the need for permissions, secrets handling, migrations, or background-runtime design.

### Proposed stack

- Deployment target: macOS 14+ (proposed compatibility baseline; validate on that OS, not just this host).
- SwiftUI scene/window composition; AppKit `NSTextView` for the composer if IME, selection, and paste tests need it. Native transcript prototype decides SwiftUI lazy list versus `NSTableView`; no embedded web chat as a shortcut.
- `@MainActor` presentation store, value-type domain DTOs, service protocols for effects.
- Core Data behind a `WorkspaceRepository` protocol with versioned model and serialized writes. Use stable UUID attributes, not managed-object IDs, at service boundaries.
- URLSession provider transport; Keychain for credentials; Foundation/OSLog for redacted diagnostics.
- App Sandbox from the first native build, outgoing network entitlement, and user-selected file access only. Security-scoped access is released after copying selected files into app-managed storage; no broad filesystem entitlement.
- XCTest/Swift Testing for domain/services and XCUITest for native UI. AppKit accessibility identifiers are part of the test contract.
- No Node sidecar, localhost server, private Cursor API adapter, or general-purpose command executor in v1.

## 2. Scope and finish line

### Required v1

| ID | Requirement | Completion evidence |
|---|---|---|
| R01 | Launchable native `.app` with the screenshot-led sidebar/chat/inspector | Local app launch plus native-window screenshot comparison |
| R02 | Create/edit/hide bots; create/edit groups; search/switch conversations | UI tests and repository restart tests |
| R03 | Persistent messages/drafts, streamed model replies, explicit offline/error/cancel states | Deterministic provider integration tests and native UI flow |
| R04 | Safe local attachments, group targeting, bot profiles, export | Boundary tests plus UI tests; no missing controls presented as finished |
| R05 | Routine CRUD, pause/resume, run-now, visible run history and honest scheduling | Fake-clock tests including sleep/relaunch and a UI run test |
| R06 | Settings for appearance, provider configuration, credentials, workspace export | Keychain/provider mock tests; secret leak scan; settings UI test |
| R07 | Computer inspector that accurately reports disconnected/unsupported | No fabricated live screen or remote-execution claim; adapter contract defined |
| R08 | Local template catalog creating independent bots | Install twice creates different IDs, with no shared conversations/credentials |
| R09 | Keyboard/VoiceOver/window-resize quality and distributable build recipe | Accessibility/manual matrix plus build/signing verification described below |

### Not silently included

Cloud VMs, browser automation, local shell execution, remote desktop control, bot-to-bot autonomous loops, multi-user cloud sync, private Grok/Cursor subscriptions, and 24/7 background jobs require separate contracts and authority. The screenshot does not prove these services are available to a new app. Voice calling is deferred; a microphone control must be absent or clearly unavailable until a speech/voice adapter is deliberately adopted.

## 3. UI contract

### UI-01 Window and layout

- One primary workspace window; use a separate native Settings scene. No fake traffic-light buttons: the window owns real system controls.
- Default sidebar 280pt, allowed 240–400pt; chat minimum 424pt; inspector default 320pt/minimum 280pt. Divider positions persist separately from domain data.
- Proposed minimum content size 760×600pt. Auto-collapse inspector when all three minima cannot fit; preserve user's preferred inspector state when widening again.
- Dark reference tokens: base `#070707`, sidebar `#111111`, agent bubble `#262626`, selected row `#353535`; system fonts, original vector avatars, real SF Symbols where appropriate.
- Reference image is a design/test artifact, not a release asset containing the user's sample conversations.

### UI-02 Sidebar and search

- Rows show avatar, name, last-message preview, timestamp, unread state; selection is independent of hover.
- Search is case/diacritic-insensitive across bot/group names and message text; names/results identify their conversation. Hidden conversations are excluded from the default list and recoverable via Hidden Chats.
- Cmd+N opens recipient picker; Cmd+F focuses search; Cmd+, opens Settings. Escape closes the top transient surface without deleting drafts or messages.
- Hide never deletes a bot or stops its routines; the action describes that behavior. Permanent delete is a separate confirmation naming impacted conversations/routines.

### UI-03 New chat, bots and groups

- Picker has existing bots, Create Bot, Create Group; keyboard arrows/Return operate a highlighted option and Escape dismisses.
- Selected group members render removable chips; proposed group size 2–6 distinct non-hidden bots; a group cannot contain itself or another group in v1.
- Create commits domain objects in one transaction; cancel does not leave ghost bots/groups.
- Edit name/description/color/shape; trimmed name 1–80 characters, description at most 8,000. Labels and limits are validated identically at UI/service boundaries.
- Group membership edits affect future replies, not the speaker attribution of existing messages.

### UI-04 Transcript and composer

- Native selectable text, timestamps, reply reference, attachment chips, partial assistant messages, error/retry and stop affordances.
- Return sends; Shift+Return inserts a newline; Return during IME marked-text composition never sends. Empty/whitespace-only text with no valid attachment cannot send.
- Drafts are keyed by conversation ID and persisted within 500ms idle and on conversation switch/app deactivation.
- Auto-scroll only when at bottom before an update; otherwise preserve visible anchor and show Jump to latest. Streaming must not steal selection or focus.
- Copy exports only the selected message text; model output is text, never executable HTML or a tool instruction with authority.
- No provider: message draft remains editable and Configure Provider is offered; sending is not represented as an AI success.

### UI-05 Inspector and editing

- Computer: disconnected by default, with a precise explanation. No placeholder wallpaper labeled live. Routine list belongs to selected bot; group routines choose an explicit owner.
- Routine editor validates name, prompt, trigger, timezone, enabled state. Show next planned run and latest terminal result/error.
- Settings, profile and routine sheets have Cancel/Save semantics; closing without saving discards edits only after a dirty-state warning.
- All image/icon-only controls have accessibility labels. Focus returns to the invoking control after dismissal.

## 4. Domain and persistence contract

Proposed stable types (Swift value types at service boundaries):

| Entity | Essential fields/invariants |
|---|---|
| Bot | UUID, name, description, avatar shape/color/image reference, createdAt, hiddenAt?, providerConfigID? |
| Conversation | UUID, kind `direct|group`, title, ordered unique memberBotIDs, createdAt, lastReadSequence |
| Message | UUID, conversationID, monotonic persisted sequence, role, speakerBotID?, immutable speakerNameSnapshot?, text, createdAt, replyToID?, attachmentIDs, generationID? |
| Draft | conversationID, text, attachmentIDs, replyToID?, updatedAt |
| Generation | UUID, conversationID, userMessageID, attemptID, targetBotID, state, lastEventSequence, error? |
| Routine | UUID, ownerBotID, name, prompt, trigger, timezoneID, enabled, nextRunAt? |
| RoutineRun | UUID, routineID, scheduledOccurrenceID?, status, startedAt?, endedAt?, generationID?, error? |
| ProviderConfig | UUID, kind, baseURL, modelID, secretKeychainReference; never the secret value |
| Attachment | UUID, originalName, mediaType, byteCount, contentHash, appManagedRelativePath |

- Bot identity and conversation identity are distinct. A group is a conversation, not a fake bot. Deleting a bot does not reuse its ID for another identity.
- Repository mutations are serialized transactions. User message and initial generation state commit atomically before any network request.
- No network request inside a persistence transaction; no managed object crosses actor/queue boundaries.
- Workspace location: app-managed Application Support directory; fixture/test stores use temporary directories. Source repo is not user-data storage.
- Schema versioned from v1; migration failure must preserve original bytes and open a recovery/error state, never silently reset to demo data.
- Export is a versioned JSON manifest plus safe attachments, excludes secrets and authentication headers, and writes atomically. Import is deferred unless separately accepted; export is not an implied import UI.
- Seed/reference data is opt-in or clearly labeled sample content. Public fixtures must be synthetic, not copied user history or claims of live external work.
- Confirmed delete policy must name counts before action: cancel active work, delete the bot's direct conversation/messages/draft and owned routine definitions/history, remove it from future group membership. Group message history retains immutable speaker-name snapshots. Groups left with fewer than two active members remain readable but require membership repair before sending. Shared provider configuration/credentials are not deleted with a bot. Remove attachment bytes only after no surviving message/draft references them.

## 5. Service and function contracts

SwiftUI calls domain services, not HTTP endpoints or Core Data directly. Suggested APIs are design contracts, not implemented signatures:

```swift
protocol WorkspaceRepository {
    func snapshot() async throws -> WorkspaceSnapshot
    func apply(_ mutation: WorkspaceMutation) async throws -> WorkspaceChange
}
protocol ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}
protocol CredentialStore {
    func read(_ reference: CredentialReference) async throws -> Data
    func write(_ secret: Data, for reference: CredentialReference) async throws
    func remove(_ reference: CredentialReference) async throws
}
protocol ComputerConnection {
    func status() async -> ComputerStatus
    func disconnect() async
}
```

| Command | Success contract | Failure contract |
|---|---|---|
| createBot / updateBot | Return persisted bot and revision; creation IDs generated once | Invalid input changes nothing; persistence error visible |
| createGroup / setMembers | Commit unique membership and conversation together | Missing/deleted member rejects transaction, no partial group |
| sendMessage | Persist user message + generation once, then stream | Save failure makes zero network calls; provider error keeps user message |
| cancelGeneration | Cancel task, persist terminal cancelled state, preserve partial text | Late events ignored; cancellation isn't an undo of an external request |
| retryGeneration | New attempt linked to same user message; visible retry provenance | Never duplicate the user message or silently resend after restart |
| hideBot / deleteBot | Hide is reversible; delete has explicit affected-record policy | Active generation cancelled before deletion; no orphan visible rows |
| saveRoutine / runNow | Validate, persist then schedule; each run has its own record | Concurrent duplicate occurrence does not create a second run |
| stageAttachment | Copy to app-managed storage after limits/path validation | Permission/size/type/disk error leaves draft unchanged |
| exportWorkspace | Produce redacted manifest and attachments at chosen location | Report failure; don't announce a partial export as complete |

### Chat state machine

```text
draft → persisting → queued → connecting → streaming → completed
                    │           │             │
                    └───────────┴─────────────→ failed
                                └────────────→ cancelled

failed/cancelled → explicit retry → new attempt
app restart with nonterminal state → interrupted (manual retry)
```

- Event envelope includes generationID, attemptID, increasing sequence and event kind: started/delta/completed/failed/cancelled.
- Ignore duplicate/out-of-order events already applied; ignore events for stale/cancelled attempts. Handle split UTF-8 and split SSE lines across network chunks.
- Proposed provider deadlines: 30s to first meaningful event, 60s idle between events, 5min total; configurable internally, deterministic in tests. No automatic retry after any response bytes without explicit provider idempotency support.
- One active generation per conversation in v1; other conversations can run independently, proposed global cap 3. Additional sends enqueue visibly and can be cancelled before transmission.
- Partial text is persisted at bounded intervals (at most 1s between flushes while active) and on terminal state. A crash may lose only the documented in-flight interval, not already committed messages.

### Group response semantics

Default target is the first explicitly selected member (shown in the composer); mentions select one or more named members. If multiple are selected, run a bounded ordered round once per selected bot, attributed in the transcript. No recursive bot-to-bot loop. The group does not claim independent workers while actually returning one anonymous canned response. Cancellation stops the remaining round and preserves completed members' replies.

## 6. Endpoint and permission contract

The installed app's `api2.cursor.sh/aiserver.v1.GrokBotService/*` paths are **research evidence only**, not an authorized integration API for this rewrite.

For the proposed SwiftUI build:
- No local HTTP API server. UI ↔ domain is typed Swift calls; provider requests are isolated in `ProviderAdapter`.
- Initial candidate provider: a specifically documented OpenAI-compatible chat-completions endpoint, configured by the user. Adapter owns `/chat/completions`, request/response mapping and SSE parsing; compatibility is proven against a fixture, not inferred from a provider's name.
- Configuration stores the API root (for example a root ending in `/v1`); append `/chat/completions` exactly once. Do not infer support for tools, images, usage accounting, resumability, or provider-side idempotency. Until the named provider is selected, the network contract is a tested adapter proposal, not proof that every compatible-looking server works.
- HTTPS required except an explicitly chosen loopback HTTP provider. Reject URL userinfo; do not forward Authorization to a different origin on redirects. Avoid logging URLs with query secrets.
- Credentials entered explicitly; protected Keychain is the default. An explicit session-only option retains the key in process memory until quit and requires re-entry on relaunch; it is never selected automatically on Keychain failure. Provider settings/export store a reference only. Keychain denial/locked/unavailable is an actionable failure, not silent plaintext fallback. Changing storage mode requires key re-entry.
- UI clearly names destination host/model and which conversation/attachments will be transmitted. Connect/test is a user action; no automatic use of credentials from the installed app.
- File access only through user selection and app-managed copies; no whole-home scan. Limit individual attachments to 10MiB and draft total to 25MiB (proposed limits). Baseline sends UTF-8 text attachments; image transmission only when adapter capability explicitly allows it; unsupported binary types fail before network transmission.
- No local tool execution in v1. A future executor must be separately reviewed with narrow per-action approval, identity/expiry binding, audit trail, deny-by-default and revocation; model text cannot grant permission.
- Remote computer integration is a future adapter contract (connection state, frames, disconnect, permission policy). V1 is honestly disconnected, not a simulated operational computer.

## 7. Routine/lifecycle contract

- Support interval minutes (minimum 5) and daily local time with a named IANA timezone. Store next occurrence in UTC and retain trigger/timezone for recomputation.
- Persist the scheduled-occurrence identifier before launching work; one in-flight run per routine. Run-now is separate from a scheduled occurrence and must not accidentally advance its calendar schedule.
- On wake/relaunch: reconcile all due schedules; run at most one missed occurrence per routine, mark older misses skipped with a reason, and advance to the next future occurrence. No burst catch-up after a week asleep.
- Daily time spring-forward gap: run at the next valid local time that day. Fall-back repeated local time: run once for that date. Interval recurrence uses elapsed absolute time.
- Pause prevents new runs; an active run requires explicit stop or is allowed to finish with UI disclosure. Delete prevents future runs and asks whether to stop an active run; history retention is described before confirmation.
- Offline/provider unconfigured: record blocked/failed reason, no fabricated result. Do not continually retry a due job in a tight loop; compute next occurrence and require explicit retry for the missed run.
- App closed, system asleep or user logged out: no execution promised. Launch-at-login/menu-bar residency, helper agents and cloud scheduling are separate opt-in followups, not hidden launch services.

## 8. Verification contract

| Test ID | Fixture/action | Required observation |
|---|---|---|
| T01 | Launch, select all seeded conversations, toggle inspector, resize 1440×900 and 760×600 | No inaccessible composer, overlapping columns or truncated action buttons |
| T02 | Screenshot at normalized 1× content coordinates; reference comparison | Major column/divider anchors within 8pt of agreed normalized baseline; typography/bubble wrapping manually reviewed. Ignore system titlebar and font rasterization in pixel diff; no misleading global pixel threshold |
| T03 | Create/edit/hide/unhide bot; relaunch | Exactly one stable identity; edits persisted; hide didn't delete routines |
| T04 | Group duplicates, 0/1/7 members, deleted member | Validation rejects; 2–6 valid members commits once; historical speaker names remain attributable |
| T05 | Stream fixture split at every UTF-8/SSE boundary | Text reconstructed exactly, correct ordering and one terminal event |
| T06 | Cancel, late delta, retry, restart midway | Partial result retained; late delta ignored; same user message, new attempt; restart shows interrupted |
| T07 | Missing key, HTTP 401/429/500, dropped stream, offline | Actionable distinct error, no secret leak, no silent successful response |
| T08 | Disk-full/save failure before send | Zero provider calls; visible persistence error; no ghost row after relaunch |
| T09 | Text/image/unsupported binary, oversize, traversal/symlink inputs | Only allowed app-managed copies; capability/type/size failures occur before transmission |
| T10 | Scheduler advance/wake/relaunch/DST, duplicate callbacks | Exactly one occurrence run; no catch-up storm; correct next-run and skip history |
| T11 | Keychain failure and workspace export/log inspection | No plaintext secret fallback; sentinel secret absent from store/export/logs/screenshots |
| T12 | Two windows or repeated launch requests | Single authoritative workspace mutation stream; no duplicate scheduled jobs |
| T13 | 10,000 persisted messages; paginated initial 100; 50 updates/sec fixture | Initial conversation presentation ≤1s on recorded Apple Silicon test host; no UI task >100ms during scroll/stream (Instruments); stale selection preserved |
| T14 | IME composition, Return/Shift+Return, Cmd+N/Cmd+F/Cmd+, Escape, VoiceOver | Correct input/focus semantics and labeled actionable controls |
| T15 | Install template twice | Independent IDs and conversations; no inherited credentials or live jobs |
| T16 | Computer panel without adapter | Explicit disconnected state; zero requests to private Grok/Cursor APIs |
| T17 | Native debug build and installed `.app` launch | App actually opens; no browser-only or screenshot-as-app substitute |
| T18 | Signing/notarization when external distribution is requested | Valid Developer ID signing + notarization/stapling evidence; unsigned local build never called distribution-ready |

Minimum OS support requires running the matrix on macOS 14 as well as this host; building with a deployment target is not equivalent evidence. If that runtime is unavailable, publish the explicit validation gap rather than claim verified support.

## 9. Risks and recovery

- **Native transcript/composer stalls:** first phase is a bounded UI/IME/performance spike. Select AppKit bridge if thresholds fail; don't rewrite the backend to compensate.
- **Looks right but is fake:** no screenshot overlay, no canned AI success, no live label on static computer content. T16/T17 are hard acceptance gates.
- **Duplicate messages/jobs:** transaction-before-effect, stable identities, attempt IDs and occurrence ledger; cancellation and crash tests are required.
- **Credential leakage:** Keychain-only secret storage, redacted diagnostics, cross-origin redirect guard, sentinel leak tests.
- **Migration loss:** versioned store, tested fixture migrations, recoverable failure instead of resetting user content.
- **Cross-platform scope changes late:** explicit ADR checkpoint before implementation. Tauri alternative changes UI/host/storage technology, not domain semantics or acceptance gates.

## 10. Proposed implementation ownership and file map

These paths are to be created after the platform decision/execution handoff:

Implementation checkpoint: the core package exists, using immutable code-defined v1 and current v2 Core Data models, explicit migration/recovery, and SwiftPM tests. Routine execution core is tested; native routine controls/lifecycle integration remain unfinished (see [routine checkpoint](ROUTINES.md)). The shell uses a SwiftPM executable packaged as a native `.app`, with a selective AppKit window/text bridge. An `.xcodeproj` is not yet generated and is not claimed as delivered. This packaging choice uses the installed Apple toolchain without introducing a project-generator dependency; release/signing and minimum-OS gates are unchanged.

```text
App/BotWorkspace.xcodeproj
App/BotWorkspaceApp.swift
App/Presentation/WorkspaceStore.swift
App/Views/{Workspace,Sidebar,Conversation,RecipientPicker,Inspector,Settings}View.swift
App/Views/Composer/NativeComposer.swift
App/Design/{Theme,AvatarShape}.swift
Packages/WorkspaceCore/Sources/WorkspaceCore/
  Domain/{Bot,Conversation,Message,Generation,Routine,Attachment}.swift
  Services/{WorkspaceService,GenerationCoordinator,RoutineScheduler}.swift
  Contracts/{WorkspaceRepository,ChatProvider,CredentialStore,Clock}.swift
App/Infrastructure/
  Persistence/{CoreDataWorkspaceRepository,WorkspaceModel.xcdatamodeld}
  Provider/{ChatCompletionsAdapter,SSEParser}.swift
  Security/KeychainCredentialStore.swift
  Files/AttachmentStore.swift
Tests/{WorkspaceCoreTests,PersistenceTests,ProviderTests,SchedulerTests}/
UITests/WorkspaceUITests/
scripts/{build,test,package}.sh
```

- Lane A: domain models/contracts, repository and migrations; owns core schema, shares DTO contract before others implement.
- Lane B: native UI, composer, avatar/layout tokens; uses fixture repository, not direct persistence/provider code.
- Lane C: provider streaming, Keychain and scheduler; depends on frozen DTO/protocol contract, uses fake clock and URLProtocol fixtures.
- Integration owner: app composition, security review, end-to-end native tests and release evidence. One owner approves shared protocol/schema changes; lanes cannot silently fork types.
- Native subagent capacity may vary: use independent bounded lanes where available; otherwise execute sequentially without dropping gates. No claim of formal consensus review is made by this document.

## 11. ADR and open decisions

**Proposed decision:** SwiftUI/AppKit macOS-first, Core Data, URLSession, Keychain, no third-party dependencies.

**Alternative:** Tauri 2 if cross-platform is a v1 requirement; use typed Rust commands, app-data storage, OS secret integration, explicit capability allowlists, same provider/scheduler state machines. WebView UI must not be described as pure native Swift controls.

**Consequences:** stronger macOS fit and existing toolchain; Windows/Linux UI is not free. Native chat performance and IME need early proof. Signing/notarization remains a separate distribution gate requiring actual signing authority.

**Open decisions:**
1. macOS-only v1 versus Windows/Linux first-release requirement (asked; controls stack choice).
2. First model provider and any existing backend contract (not supplied; keep adapter explicit).
3. Final app name/bundle identifier and distribution channel (working identifiers only until chosen).

Implementation must not treat a mock provider as proof of a real credentialed integration or declare the original new-app goal complete when only this plan exists.

## 12. Sources and independent review

An independent dependency specialist compared the options against official sources and recommended SwiftUI/AppKit for macOS-first, Tauri for a first-release cross-platform requirement. This is an advisory stack review, **not** formal Architect/Critic consensus or implementation approval.

Primary sources:
- [Apple NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview): multi-column native navigation composition. Custom split/layout behavior still requires testing against this app's reference.
- [Apple NSTex​tView](https://developer.apple.com/documentation/appkit/nstextview) and [NSViewRepresentable](https://developer.apple.com/documentation/swiftui/nsviewrepresentable): native text editing and SwiftUI/AppKit integration.
- [Apple NSPersistentContainer](https://developer.apple.com/documentation/coredata/nspersistentcontainer): Core Data stack and background contexts; migration and model design remain app responsibilities.
- [Apple macOS Keychains guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains): appropriate secret storage and modern Keychain API guidance.
- [Apple URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask): native WebSocket support if a future adapter needs it; this does not prescribe WebSockets for chat-completions SSE.
- [Apple SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice): possible later login-item/helper registration, not permission to promise work while a Mac is asleep/off.
- [Apple App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox) and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution): entitlements and distribution requirements.
- [Tauri architecture](https://v2.tauri.app/concept/architecture/) and [capabilities](https://v2.tauri.app/security/capabilities/): WebView/Rust boundaries and command permissions; system permissions remain a separate obligation.

Recommendations deliberately exclude unmeasured performance/security superiority claims and do not add dependencies or credentials.
