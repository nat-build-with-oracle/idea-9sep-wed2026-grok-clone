# Workspace screens and interaction contract

Status: **implemented-source inventory with bounded verification references** · 2026-09-10

This document is the screen-by-screen contract for the main BotWorkspace window and the
transient surfaces opened from it. It describes the current native SwiftUI/AppKit source,
not an imagined Grok service and not a promise that every rendered fixture has passed a
physical mouse, keyboard, IME or VoiceOver run.

The stable IDs `W01`–`W19` are also screenshot-catalog slots. A catalog may associate a
private reference image or a generated app capture with an ID, but this public document
does not invent filenames for those images. The source remains authoritative when an old
capture disagrees with it.

## Status and evidence vocabulary

| Label | Meaning |
|---|---|
| **Implemented** | The control, state or transition exists in current app source. |
| **Fixture/sample-only** | It exists only in the non-durable preview or a synthetic verifier. It must not be presented as live provider/computer behavior. |
| **Planned/not implemented** | The contract names the desired boundary, but no usable control/service exists yet. |
| **Test-covered** | A focused automated test exists for the stated logic. This does not prove physical interaction or visual correctness. |
| **Rendered fixture** | An isolated smoke can render the app-owned view. This does not prove real credentials, networking, OS permission prompts, window focus or assistive-technology behavior. |
| **Live-validated** | Requires explicit evidence from a real user/runtime path. This document does not infer it from unit tests or fixture screenshots. |

### Global implementation boundary

- **Implemented:** native macOS window, local Core Data workspace, named bots, direct and
  group conversations, drafts, text attachments, reply references, provider selection,
  streamed text, ordered group rounds, profile editing and local templates.
- **Fixture/sample-only:** the preview bundle's synthetic conversations, timestamps and
  local-only “send” behavior; offline provider and smoke responses.
- **Planned/not implemented:** a connected computer/desktop/terminal inside the inspector.
  The current product contract explicitly excludes remote desktop, shell execution and
  private Grok/Cursor endpoints without a separate adapter and authority.
- **Not claimed here:** XCUITest coverage, full physical keyboard/IME/VoiceOver coverage,
  macOS 14 runtime completion, broad provider compatibility, real file-picker sandbox
  grants, release signing/notarization or production Keychain success.

Primary scope evidence:

- `README.md:7-13,35-37,51-69`
- `DESIGN.md:3-7,18-22,34-41,43-71,87-93`
- `docs/NATIVE-REWRITE-CONTRACT.md:53-71,73-113,202-215`
- `docs/DURABLE-WORKSPACE.md:58-79,84-125`

## Screen index

| ID | Screen or state | Current status | Screenshot catalog intent |
|---|---|---|---|
| W01 | Desktop three-pane workspace | Implemented | Wide canonical workspace |
| W02 | Minimum-width workspace | Implemented; inspector auto-collapses | 760×600 responsive boundary |
| W03 | Sidebar, search, activity and hidden-chat recovery | Implemented | Search/unread/menu variants |
| W04 | Direct conversation and message actions | Implemented | Direct chat baseline |
| W05 | Group conversation with manual ordered recipients | Implemented | Group composer/manual order |
| W06 | Typed and menu-inserted group mentions | Implemented | Valid, duplicate and invalid mention states |
| W07 | New direct-chat recipient picker | Implemented | Single-recipient picker |
| W08 | Group builder | Implemented | Chips, limits and create state |
| W09 | Reply selection, composer preview and jump states | Implemented | Available/loading/unavailable references |
| W10 | Draft text-attachment ingress and chips | Implemented in durable app | File-copy progress/chips/errors |
| W11 | Transmission consent sheet | Implemented | Direct-file and group-round disclosure |
| W12 | Streaming, failed, cancelled and retry status | Implemented | Generation lifecycle states |
| W13 | Disconnected computer inspector | Implemented honest placeholder | Required disconnected capture |
| W14 | Marketplace/local templates | Implemented local catalog | Template sheet |
| W15 | Account/display-name sheet | Implemented | Profile sheet |
| W16 | Edit Bot sheet | Implemented | Validation/save/conflict states |
| W17 | Edit Group sheet | Implemented | Ordered membership editor |
| W18 | Degraded group requiring membership repair | Implemented | Readable-but-unsendable group |
| W19 | Global opening/saving/storage-error overlays | Implemented | Blocking and recovery states |

## Global shell and navigation contract

### Navigation hierarchy

```text
Application launch
  |
  +-- persistent BotWorkspace bundle / --workspace
  |     `-- open local Core Data workspace
  |
  `-- sample preview bundle
        `-- seed synthetic in-memory conversations

Main workspace
  |
  +-- Sidebar --------------------------------------------------+
  |     +-- conversation row --> Direct/Group conversation      |
  |     +-- + / Cmd+N -------> Recipient picker                 |
  |     +-- Marketplace -----> W14 sheet                        |
  |     `-- account ---------> W15 sheet                        |
  |                                                               |
  +-- Conversation ---------------------------------------------+
  |     +-- Edit -----------> W16/W17 sheet                      |
  |     +-- Routines -------> separate routine sheets            |
  |     +-- provider gear --> separate Settings window           |
  |     `-- details -------> show/hide inspector                 |
  |                                                               |
  `-- Inspector -------------------------------------------------+
        +-- Settings -------> separate Settings window
        +-- Edit -----------> W16/W17 sheet
        `-- Computer -------> W13 disconnected state only
```

### App-wide shortcuts and escape order

| Input | Action | Evidence |
|---|---|---|
| `Command-N` | Open new-chat picker | `NativeShellApp.swift:1306-1310,1346` |
| `Command-F` | Force sidebar visible and focus conversation search | `NativeShellApp.swift:1312-1320,1452-1455`; `WorkspaceView.swift:148-176,239` |
| `Command-,` | Open Settings | `NativeShellApp.swift:1297-1304,1347,1354-1379` |
| `Command-Q` | Quit through save/dirty-state guards | `NativeShellApp.swift:1297-1304`; close flow at `162-205` |
| `Command-W` | Close the key window | `NativeShellApp.swift:1306-1310` |
| Return in composer | Submit only for unmodified Return with no marked text | `NativeComposer.swift:64-81`; `Models.swift:84-89` |
| Shift-Return | Insert newline | `NativeComposer.swift:70-81`; tests `PreviewWorkspaceTests.swift:293-312` |
| Escape | Cancel the top transient surface in defined priority; profile/routine dirty handling remains owned by its editor | `WorkspaceView.swift:95-112` |

Escape priority is:

```text
attachment consent
  > routine editor/detail
  > bot-deletion confirmation
  > profile editor
  > simple panel (marketplace/account/sample forms)
  > recipient picker
  > dismiss workspace notice
```

The separate Settings window has its own dirty-close contract and is only referenced here
as an exit destination. Its fields belong in the Settings screen contract, not this file.

---

## W01 — Desktop three-pane workspace

**Status:** Implemented. Wide synthetic rendering exists; a rendered fixture is not a
physical interaction or live-service result.

**Entry:** Launch the durable app or close any transient picker/sheet while the workspace
window remains open. A persistent launch opens the local store; a sample launch seeds
synthetic data.

**Exit:** Select another conversation without leaving the screen; open picker, Settings or
a sheet; close/quit the window.

```text
+---------------------------+--------------------------------------+---------------------------+
|                         + | [avatar] Conversation      [edit][◷][details] | [settings][hide] |
| [ Search_____________ x ] |--------------------------------------|---------------------------|
|                           |                                      | Edit Bot / Edit Group      |
| [avatar] Conversation  9m |          transcript                   | profile/member summary     |
|          preview       (2)|                                      |                           |
| [group]  Team          Sep|    assistant message                  | +-----------------------+ |
|          latest reply     |    [reply ref]                        | | desktop icon          | |
|                           |    [bubble] [Reply] [Copy]             | | No computer connected | |
|                           |                         user [bubble]  | | no service configured | |
|                           |                                      | +-----------------------+ |
|                           | [provider] [group targets if needed]  | Bot/Group's screen        |
|                           | [reply / notice / attachment chips]   |                           |
| [Marketplace]             | (+) [Message…________________] [send] | Routines                  |
| [account name]            |                                      |                           |
| saved/provider status     |                                      |                           |
+---------------------------+--------------------------------------+---------------------------+
```

### First-run / no conversation selected substate

**Status:** Implemented; not separately captured in the published screenshot set.

**Entry:** Open a newly created workspace with no bots/conversations, or reach the
workspace with no current conversation selected. This is different from an existing
conversation that merely has no messages.

```text
+--------------------------+--------------------------------------------+
|                       +  |                                            |
| Search conversations     |                                            |
|                          |           Choose a conversation            |
| [existing rows, if any]  | Or create your first bot with the + button. |
|                          |                                            |
| Marketplace              |        no transcript or composer           |
| Account                  |                                            |
+--------------------------+--------------------------------------------+
```

**Actions/exit:** Select an existing sidebar conversation to display it, or use the
sidebar **+** / `Command-N` to open W07 and create or choose a bot. The center message
is explanatory text, not a clickable creation button. Transcript and composer are
omitted while `store.current` is absent; no send or remote connection is started.
The ordinary local persistence and shell keyboard/accessibility rules still apply.

**Evidence:** `Prototypes/NativeShell/Sources/NativeShell/WorkspaceView.swift:340-349`;
new-chat navigation follows W07. ASCII/source coverage only; do not use a populated
fixture as visual evidence of a clean first launch.

### Layout contract

- The root view is an `HStack` containing conditional sidebar, flexible middle surface and
  conditional inspector. Draggable one-point dividers separate panes.
- The app window defaults to `1280×880`; content cannot resize below `760×600`.
- Default saved pane widths are sidebar `280pt` and inspector `320pt`.
- User-adjustable bounds are sidebar `240…400pt` and inspector `280…440pt`.
- The transcript retains a `424pt` minimum plus divider allowance. The inspector appears
  only when `container >= displayedSidebar + inspector + 426` and no picker is open.
- Divider drag writes the preference immediately. Accessibility increment/decrement changes
  the active width by `20pt` within bounds and reports the displayed width.
- Appearance is Dark, Light or Follow System; Dark is the default. Widths/visibility live
  in versioned app preferences, separate from Core Data and workspace export.

### Persistent and service boundaries

- Persistent startup opens `Application Support/BotWorkspace/workspace.sqlite`.
- Sample startup creates in-memory synthetic records and does not contact a provider.
- The root disables all content while opening or closing the workspace.
- Provider effects do not originate from the view; they route through the presentation
  store and generation coordinator.
- No incoming network server, shell executor or computer adapter exists in this screen.

### Accessibility

- Icon-only controls use explicit labels through `ShellIconButton`.
- Pane dividers expose “Resize pane,” a point value and adjustable actions.
- This source-level accessibility contract is not a completed VoiceOver audit.

### Evidence

- Structure/minimum/sheets: `Prototypes/NativeShell/Sources/NativeShell/WorkspaceView.swift:5-70`
- Dividers: `WorkspaceView.swift:117-145`
- Window construction: `NativeShellApp.swift:44-110`
- Layout calculation: `WorkspaceLayout.swift:3-19`
- Preference defaults/bounds: `WorkspacePreferences.swift:20-60`
- Tests: `AppearanceWorkspaceTests.swift`; `WorkspacePreferencesTests.swift`;
  `ThemeTests.swift`; `NativeComposerAppKitTests.swift`
- Verification limits: `docs/APPEARANCE.md:48-74`

---

## W02 — Minimum-width workspace

**Status:** Implemented responsive state. A minimum-size render exists in isolated smoke
paths; physical resizing and assistive technology remain manual gates.

**Entry:** Resize content to `760×600`, or launch the isolated verifier with its minimum
fixture option.

**Exit:** Widen the window; open a picker; toggle sidebar/details preference.

```text
+----------------------+----------------------------------------------+
|                    + | [avatar] Conversation          [edit][◷][>] |
| [ Search________ x ] |----------------------------------------------|
| [row]                 | transcript                                   |
| [row]                 |                                              |
| [row]                 |                                              |
|                       | [provider / target controls]                 |
| [Marketplace]         | (+) [Message…_______________________] [send] |
| [account]             |                                              |
+----------------------+----------------------------------------------+
                     inspector omitted, preference preserved
```

### Exact responsive behavior

- Minimum window content: `760×600`.
- If a saved sidebar width would squeeze the middle pane, the displayed sidebar becomes
  `min(savedWidth, max(240, containerWidth - 425))`. At 760 with a saved 400pt sidebar,
  this is 335pt. The stored 400pt value is not overwritten.
- Inspector auto-collapse is derived from current width and does not set
  `inspectorPreferred = false`; widening can restore it.
- Opening W07/W08 also hides the inspector regardless of available width.
- If the sidebar is hidden, the middle pane supplies a “Show sidebar” icon in its header.

### Accessibility and gaps

- The hidden inspector is not presented as disconnected content that happens to be
  off-screen; it is absent from the hierarchy due to the layout decision.
- No mobile/reflowed navigation is promised. This is a desktop minimum, not a phone layout.
- Horizontal behavior for exceptionally wide code/text content is not separately proven.
- The current isolated visual run reports that the minimum composer fits within the
  supported viewport. Treat that as rendered-fixture evidence, not physical input proof.

### Evidence

- `WorkspaceLayout.swift:3-19`
- `WorkspaceView.swift:9-39,353-393`
- `WorkspacePreferences.swift:20-60`
- `docs/APPEARANCE.md:16-24,57-74`
- Tests: `AppearanceWorkspaceTests.swift`; `WorkspacePreferencesTests.swift`

---

## W03 — Sidebar, search, activity and hidden-chat recovery

**Status:** Implemented. Unread/read-state logic is extensively test-covered; real window
focus could not be inferred from the locked-host fixture and remains explicitly unverified.

**Entry:** Visible by saved preference at launch; reveal through the middle header or
`Command-F`; use View → Toggle Sidebar.

**Exit:** Toggle sidebar off, open W07/W08, or select a conversation and continue in W04/W05.

```text
+------------------------------+
|                            [+]  New chat
| [magnifier] Search_______ [x] |
|                              |
| [avatar] Research       9:06 |
|          latest preview [99+]|
| [group]  Team          Sep 9 |
|          draft/reply        2|
|                              |
|         No conversations     |  empty result state
|       Try another name…      |
|                              |
| [grid] Marketplace           |
| [user] Display name          |
| • Saved on this Mac · …      |
+------------------------------+

Conversation row context menu:
  Edit Bot… / Edit Group…
  Hide from sidebar / Unhide conversation   (direct only)
  Delete Bot…                               (durable direct only)
  Copy conversation name
```

### Controls and actions

| Control | Action and result |
|---|---|
| `+` | Opens W07 and clears previous picker query/selection/highlight. |
| Search field | Filters by conversation title and message text. Durable search asks the repository; sample search uses loaded in-memory rows. |
| Clear-search `x` | Sets query to empty. |
| Conversation row | Flushes durable drafts before changing selection, loads latest 100 messages, clears notices and returns focus to composer. |
| Row context: Edit | Opens W16 or W17, bound to stable identity. |
| Row context: Hide | Persists `hiddenAt` for direct bot; does not delete it or clear unread state. |
| Row context: Unhide | Available when hidden rows have been enabled in Settings. |
| Row context: Delete Bot | Opens the dedicated destructive confirmation; only durable direct rows expose it. |
| Row context: Copy name | Writes only the conversation title to the macOS pasteboard. |
| Marketplace | Opens W14. |
| Account | Opens W15. |

### Search and hidden-state contract

- Durable search is case- and diacritic-insensitive across title/message content.
- Whitespace around a non-empty query is trimmed by presentation filtering; repository
  result identities decide visible durable rows.
- Hidden direct conversations are excluded by default. “Show hidden conversations” lives
  in Settings, not as an inline sidebar disclosure. When enabled, hidden rows can be found
  and their context menu changes to “Unhide conversation.”
- Groups are not hidden through this menu.
- Empty results show “No conversations found / Try another name or message.”
- Search failures surface as the global storage error overlay rather than silently showing
  authoritative empty results.

### Activity and read acknowledgement

- Each durable row displays persisted latest-message preview/date and exact unread
  **assistant** reply count. User/event rows do not increment it.
- Visual count caps at `99+`; the row's accessibility value includes the full count.
- Preview fallback is “Start a conversation.” Attachment-only latest messages use a generic
  text-attachment label from the repository projection.
- Selecting/loading a chat does not by itself mark it read.
- Automatic acknowledgement requires: durable repository; active app; visible/key,
  non-minimized main window; no obscuring picker/sheet/dialog/file operation; selected
  conversation; rendered bottom exactly visible; rendered latest identity/sequence/UTF-8
  byte count equal to the current snapshot; no nonterminal generation.
- A failed read write/refresh preserves the badge and displays “Retry read status.”

### Accessibility

- A row combines title, preview, full date/time where present and exact unread count into
  one accessibility element; selected rows add the selected trait.
- The visual badge is hidden from accessibility to avoid duplicate announcements.
- Search, new chat, Marketplace and account controls have identifiers.

### Evidence

- Sidebar UI: `WorkspaceView.swift:148-240`
- Row UI/menu/a11y: `WorkspaceView.swift:243-321`
- Projection/filter/select: `Models.swift:243-329`
- Durable search/load/draft flush: `PersistentWorkspace.swift:119-156,173-225`
- Hide persistence: `PersistentWorkspace.swift:256-268`
- Activity/read gate: `ConversationActivityWorkspace.swift:22-123,140-156`
- Repository query test: `WorkspaceCoreTests/RepositoryTests.swift:320-327`
- Exact count test: `WorkspaceCoreTests/ConversationActivityTests.swift:99-121`
- Native tests: `ConversationActivityWorkspaceTests.swift:8-272`;
  `PreviewWorkspaceTests.swift:229-264`
- Live-focus limitation: `docs/UNREAD-CONVERSATIONS.md:68-80`

---

## W04 — Direct conversation and message actions

**Status:** Implemented. Durable sending requires a configured provider and usable
credential. Preview sending is explicitly local/session-only.

**Entry:** Select a direct row in W03 or select a bot in W07.

**Exit:** Select another row, open a transient surface, or close the app.

```text
+------------------------------------------------------------------+
| [bot] Bot name                             [edit] [routines] [>]  |
|------------------------------------------------------------------|
|                   [timestamp]                                    |
|                                                                  |
| Assistant name                                                   |
| +--------------------------------------+                         |
| | assistant text                      |                         |
| +--------------------------------------+                         |
| [Reply] [Copy]                                                   |
|                                                                  |
|                                  +-----------------------------+ |
|                                  | user text                   | |
|                                  +-----------------------------+ |
|                                  [Reply] [Copy]                  |
|                                                                  |
| Provider: [Choose provider v] [gear]                              |
| To: https://…/v1 · model-id                                      |
| (+) [Message Bot name_______________________________] [↑]         |
+------------------------------------------------------------------+
```

### Header

- Bot avatar and current conversation title.
- Edit button opens W16.
- Durable conversations expose a Routines menu. Routine details/editor are documented in
  `docs/ROUTINES.md` rather than expanded here.
- Details toggles inspector preference; the inspector may still auto-collapse at W02 width.

### Transcript

- Latest page loads 100 messages. “Load earlier messages” prepends another 100 when a
  cursor exists, preserving stable message IDs and the current visible set.
- Default scroll anchor is bottom. If the user is no longer near bottom, new/streamed text
  preserves position and shows “Jump to latest.”
- User messages align right; assistant messages align left; event messages are centered
  plain status text. Message text is selectable.
- Assistant messages can show immutable speaker-name snapshots. This matters after bot
  rename/deletion and for group attribution.
- Text attachments render read-only chips beneath text. Missing metadata renders an
  explicit unavailable chip.
- A timestamp is a separate centered row above the message.

### Message actions

- The current implementation uses visible **Reply** and **Copy** buttons under every
  non-event message, not an ellipsis or message context menu.
- Reply is disabled for a message with neither text nor attachments.
- Copy writes only message text and is disabled for attachment-only messages.
- No reaction, edit-message, delete-message, forward or execute action is implemented.

### Composer and send validation

- Plain-text AppKit `NSTextView`, selectable/editable, undo enabled, graphics import off,
  vertical scroller automatic, height clamped to `36…130pt`.
- Return submits; Shift-Return inserts a newline; Control/Option/Command-Return do not use
  the submit path; marked-text Return never submits.
- Send is disabled when text trims empty and there are no attachments, or during submit,
  deletion, attachment import/confirmation, unresolved mention insertion, invalid group
  mention, or membership repair.
- Draft is conversation-scoped. Durable edits schedule a 300ms debounced save and flush on
  conversation switch/app deactivation/close.
- No provider: Send preserves/flushes the draft, creates no message and shows an explicit
  local notice. Provider choice is a session selection, not a persisted per-bot default.
- Selected provider displays exact API root and model. Disclosure says the request includes
  the draft, bot description, up to 100 recent messages, the older parent when replying,
  and any applicable text files.
- Direct text-only submit needs no extra consent sheet. A direct request that transmits text
  attachments opens W11.

### Empty conversation state

```text
                         [large bot avatar]
                         A new conversation
        Your drafts are saved on this Mac. Choose a provider below…
```

Sample mode instead states that messages remain in this session and no AI provider is
contacted.

### Accessibility

- Composer label: “Message composer.”
- Buttons identify edit, routines, details, provider, settings, attachment and send actions.
- Speaker attribution uses “Reply from <name>.”
- Message text remains selectable, but no claim of complete rotor order or live-region
  behavior is made.

### Evidence

- Header/transcript/autoscroll: `WorkspaceView.swift:324-513`
- Composer/provider controls: `WorkspaceView.swift:515-771`
- Message presentation/actions: `WorkspaceView.swift:840-919`
- AppKit composer: `NativeComposer.swift:4-151`
- Draft persistence: `Models.swift:251-258`; `PersistentWorkspace.swift:173-225`
- No-provider behavior: `PersistentWorkspace.swift:285-309`
- Tests: `NativeComposerAppKitTests.swift`; `PersistentWorkspaceTests.swift:45-66,92-121`;
  `ProviderWorkspaceTests.swift:212-274`; `PreviewWorkspaceTests.swift:166-227`

---

## W05 — Group conversation with manual ordered recipients

**Status:** Implemented. Ordered-round orchestration is fixture-tested; broad live-provider
behavior and physical control operation are not inferred.

**Entry:** Select a group row in W03 or create one in W08.

**Exit:** Navigate to another chat, edit group, or complete/cancel the send flow.

```text
+------------------------------------------------------------------+
| [group] Project team                       [edit] [routines] [>]  |
|------------------------------------------------------------------|
| transcript with attributed replies                               |
| Research Partner                                                 |
| [first reply bubble]                                             |
| Writing Partner                                                  |
| [second reply bubble]                                            |
|------------------------------------------------------------------|
| Provider: [Provider v] [gear]                                    |
| Reply as                         [Mention v] [2 selected v]        |
|  1. Research Partner                         [↑][↓][x]            |
|  2. Writing Partner                          [↑][↓][x]            |
| One ordered request per bot. Review before sending.              |
| (+) [Message Project team__________________________] [↑]          |
+------------------------------------------------------------------+
```

### Manual recipient contract

- “Choose group reply bots” lists current group members only.
- Selecting appends identity to the ordered target list; deselecting removes it.
- The displayed numbered list is authoritative. Up/down swaps adjacent positions; remove
  deletes the target. List height caps at 82pt and scrolls.
- Selection order is session presentation state scoped by conversation. It is not persisted
  as a per-group default.
- Zero targets blocks sending with “Choose one or more bots…” at the service boundary.
- One manually selected target follows single-send behavior. Two or more targets create a
  bounded ordered round and always open W11, even with no files.
- One user message is persisted for the round. Each recipient receives a separate request
  and produces an attributed reply.
- Every recipient uses the same frozen pre-round context; later recipients do not see prior
  replies from that same round.
- Stop on any unfinished member becomes “Stop round,” cancels remaining siblings and keeps
  completed replies. Provider failures remain visible per member and do not silently retry
  or stop later approved recipients.

### Persistence/network boundary

```text
draft + ordered target IDs + provider
  -> prepare aggregate plan (no credential/network)
  -> W11 review
  -> revalidate draft/provider/targets/context
  -> read credential
  -> atomically commit one user message + all queued generations
  -> send separate requests in displayed order
```

A changed draft, destination or target order invalidates prior review. An older send cannot
clear a newer draft version.

### Accessibility

- Target menu reports “None selected” or the count.
- Each numbered target includes full identity in help/accessibility text. Move/remove
  controls name the bot and direction/action.
- Duplicate display names receive a distinguishing identity prefix.

### Evidence

- Group provider controls: `WorkspaceView.swift:653-755`
- Ordered selection store: `ProviderWorkspace.swift:29-68`
- Command capture/round split: `ProviderWorkspace.swift:146-181`
- Round submission: `ProviderWorkspace.swift:215-242`
- Stop/retry: `ProviderWorkspace.swift:245-275`
- Tests: `ProviderWorkspaceTests.swift:276-668`; core
  `WorkspaceCoreTests/GroupRoundCoordinatorTests.swift`
- Detailed contract: `docs/GROUP-ROUNDS.md`

---

## W06 — Typed and menu-inserted group mentions

**Status:** Implemented. Parser and workspace routing are test-covered; physical IME/menu/
VoiceOver operation remains an open gate.

**Entry:** In W05, type a supported mention or choose a member from the Mention menu.

**Exit:** Remove all mentions to restore manual targets, correct an invalid mention, or send
through W11.

```text
Reply as                         [Mention v] [manual disabled]
Recipients from mentions
  1. Research Partner
  2. Writing Partner
Mention order replaces manual selection…

(+) [Ask @Research then @"Writing Partner"_________] [↑]

Invalid variant:
  No current group member matches this mention…
  [send disabled]
```

### Supported user syntax

```text
@Research
@"Writing Partner"
\@literal-handle
```

- Matching is case-sensitive after Unicode NFC normalization.
- A mention starts at text start, whitespace, or supported separator/opening punctuation.
- Bare names use Unicode letters/numbers, `_` or `-`. Spaces/punctuation require quoted
  JSON-string syntax.
- Emails, URL spans, inline code and fenced code are not routing instructions.
- `\@` at a mention boundary produces literal `@` and retains manual recipient behavior.
- Duplicate unbound names fail as ambiguous. Menu insertion writes a quoted token with a
  local UUID binding so exact identity survives duplicate names and app restart.
- Repeated mentions deduplicate the recipient but preserve first-occurrence order.
- At most six unique targets are allowed.

### Menu insertion safety

- Mention menu contains current group members and exposes display name plus full UUID in
  help/accessibility text.
- Insertion occurs at current selection/caret and adds separators when needed.
- It is one-shot and bound to conversation ID, composer context generation and exact
  expected draft body.
- It rechecks that the editor is editable/selectable and has no marked text.
- Navigation, reconnect, draft change, a different insertion or IME marked text rejects the
  delayed command. Failure leaves content unchanged and asks the user to try again.
- While insertion is pending, Send is disabled.

### Routing and disclosure

- Any valid mention set replaces the manual target list; manual controls are disabled but
  their previous state remains for later mention-free drafts.
- Invalid/incomplete/unknown/ambiguous/stale/bad-binding mentions show the first issue inline
  and block Send. They never fall back silently to manual targets.
- Any mention send is represented as a round and opens W11, even for one recipient.
- Raw UUID binding syntax is local draft consent state only. The provider and stored
  transcript receive readable message text with binding suffixes removed.
- Confirmation explains that recipients came from mentions and local identity bindings are
  not sent.

### Evidence

- UI: `WorkspaceView.swift:653-755`
- Routing/insertion store: `MentionWorkspace.swift:4-101`
- One-shot AppKit insertion: `NativeComposer.swift:88-142`;
  `ComposerInsertion.swift:3-22`
- Parser and errors: `Packages/WorkspaceCore/Sources/WorkspaceCore/GroupMentions.swift:3-180`
- Native tests: `MentionWorkspaceTests.swift:19-335`;
  `NativeComposerAppKitTests.swift:79-210`
- Parser tests: `WorkspaceCoreTests/GroupMentionTests.swift`
- Detailed grammar/limits: `docs/GROUP-MENTIONS.md`
- Screenshot-catalog caution: the current capture set contains generic mention-labelled
  records whose pixels duplicate the invalid Dark state. Do not map those records to W06's
  valid baseline merely from their record name; use the mention-specific valid, duplicate
  identity and invalid-state captures and verify pixels/provenance in the master catalog.

---

## W07 — New direct-chat recipient picker

**Status:** Implemented.

**Entry:** Sidebar `+` or `Command-N`.

**Exit:** Choose an existing bot, switch to W08, open Create Bot, press Escape or close `x`.

```text
+------------------------------------------------------------------+
| To: [Search or create Bots____________________________] [x]      |
|------------------------------------------------------------------|
| +--------------------------------------------------------------+ |
| | (+) Create new Bot                                           | |
| | (group) Create group chat                                    | |
| | [bot] Research Partner                          New chat      | |
| | [bot] Writing Partner                                        | |
| +--------------------------------------------------------------+ |
|                                                                  |
+------------------------------------------------------------------+
```

### Behavior

- Picker replaces the entire middle conversation surface and forces inspector hidden.
- Query receives focus on appearance. Case-insensitive localized name filtering occurs
  over visible, unselected bots.
- Up/down commands move a highlighted existing bot; Return chooses it.
- Choosing an existing bot opens its already-created direct conversation. It does not
  create a duplicate direct chat.
- “Create new Bot” opens the simple creation panel with name, description, shape and color.
  Name must trim to 1…80 characters; creation makes distinct bot and conversation IDs.
- “Create group chat” reinitializes the picker in W08 mode.
- Hidden bots are not offered.
- “No matching bots” is shown when filtering produces no available recipients.

### Persistence/network/permission boundary

- Durable Bot creation is one repository mutation followed by refresh and selection.
- Sample Bot creation mutates only preview memory.
- Creating/opening a chat does not read credentials or contact a provider.
- Cancel does not create a ghost Bot or conversation.

### Accessibility

- Query and create actions are native controls. Existing rows say “Chat with <name>.”
- Cancel icon has “Cancel new chat.”
- Highlight visuals do not replace semantic button activation.

### Evidence

- `RecipientPickerView.swift:3-76,108-137`
- Picker state/selection: `Models.swift:278-345`
- Durable creation: `PersistentWorkspace.swift:228-244`
- Tests: `PreviewWorkspaceTests.swift:29-80`;
  `PersistentWorkspaceTests.swift:17-43,123-145`

---

## W08 — Group builder

**Status:** Implemented.

**Entry:** W07 → “Create group chat,” or programmatically open group picker.

**Exit:** Create the group, cancel, or press Escape.

```text
+------------------------------------------------------------------+
| To: [Search or create Bots____________________________] [x]      |
|------------------------------------------------------------------|
| [bot A  x] [bot B  x] [bot C  x]       selected chips            |
| +--------------------------------------------------------------+ |
| | [bot] Another member                         Add to group chat | |
| | [bot] Another member                                           | |
| +--------------------------------------------------------------+ |
|                                                                  |
| [Group name____________________] [Create group]                   |
| Choose two to six bots. This group is saved on your Mac.         |
+------------------------------------------------------------------+
```

### Behavior and validation

- Each selection appends an ordered UUID and becomes a removable chip.
- Selected bots disappear from candidates. Removing a chip returns a non-hidden bot to the
  candidates.
- Group size is 2…6 unique, available, non-hidden bots. Candidate controls disable at six;
  empty candidates show “Six bots selected” or “No matching bots.”
- Default name is “New group chat.” Name must trim to 1…80 characters.
- “Create group” is disabled below two recipients and uses `Command-Return` as its explicit
  shortcut.
- Service validation repeats all membership/name rules; an error is shown beneath the form
  and no partial group is committed.
- Successful creation selects the new group and returns to W05.

### Persistence/network boundary

- Durable create is one repository group mutation and preserves selected member order.
- No provider request, credential access or autonomous member conversation occurs.
- A group is a conversation identity, not a Bot identity or nested group.

### Accessibility

- Candidate labels say “Add <name>.” Chip removal says “Remove <name>.”
- Group name and create button expose stable identifiers.
- Complete keyboard traversal/VoiceOver order remains a manual gate.

### Evidence

- `RecipientPickerView.swift:21-40,42-105`
- Selection/create validation: `Models.swift:318-361`
- Durable creation: `PersistentWorkspace.swift:246-254`
- Tests: `PreviewWorkspaceTests.swift:82-164`;
  `PersistentWorkspaceTests.swift:17-43`

---

## W09 — Reply selection, composer preview and jump states

**Status:** Implemented.

**Entry:** Press Reply under a non-event message in W04/W05, or reopen a durable draft that
already contains `replyToID`.

**Exit:** Cancel reply, send successfully, replace it by replying to another message, or
navigate away while retaining its conversation-scoped draft.

```text
Transcript child reply:
  +-- [Original sender]
  |   [two-line original excerpt]
  +-- [reply bubble]

Composer:
  +----------------------------------------------------------+ [x]
  | Original sender                                          |
  | two-line excerpt…                                        |
  +----------------------------------------------------------+
  [existing draft text remains unchanged____________________]

States:
  Loading original message… [spinner]
  Original message unavailable / It may have been removed…
  Available -> click to load/jump to original
  Opening -> spinner; repeated open disabled
```

### Contract

- Selecting a parent never sends, switches conversation or changes draft text.
- Parent must be a non-event message in the same conversation with text or attachments.
- Reply choice and text/attachment IDs persist together as one conversation draft.
- Preview sender uses recorded speaker name (`You`, assistant snapshot or fallback), not a
  bot's newly edited name. Excerpt collapses whitespace and caps at 180 characters.
- Attachment-only parents show “N stored text attachment(s).”
- Cancel removes only the parent reference and leaves text/attachments.
- Child messages show their reply reference above the bubble.
- Available reference cards are clickable. A jump loads contiguous older 100-message pages
  until the target is present, then centers it without changing conversation.
- Loading/unavailable references do not activate. Lookup failure is cached; an explicit
  conversation reload can retry unavailable references.
- Any stale navigation/context/request result is ignored. Jump failure keeps draft intact
  and shows an explicit notice.
- Provider context includes the explicit older parent exactly once when outside the normal
  recent window. It remains an ordinary role/content turn, never a system instruction.

### Accessibility

- Available preview announces “Reply to <sender>: <excerpt>.” Loading and unavailable have
  explicit labels.
- Composer preview has a separate “Cancel reply” control.
- Opening progress announces “Opening original message.”
- Current visual QA reports that the top reply bubble is clipped in the captured viewport.
  That image may still prove the lower composer reference state, but it must not be used as
  evidence that the full referenced transcript row is visually complete.

### Evidence

- Presentation: `ReplyPreviewView.swift:3-100`
- Workspace state and jump: `ReplyWorkspace.swift:4-219`
- Transcript/composer integration: `WorkspaceView.swift:488-502,528-539,867-880`
- Tests: `ReplyPresentationTests.swift:7-31`; `ReplyWorkspaceTests.swift:9-274`
- Detailed contract/fixture limits: `docs/REPLY-WORKFLOW.md`

---

## W10 — Draft text-attachment ingress and chips

**Status:** Implemented only in durable BotWorkspace. Sample mode never reads files.

**Entry:** Press the composer `+` in W04/W05 and choose files in the native open panel.

**Exit:** Cancel selection, complete copy into the draft, remove chips, or proceed to W11.

```text
Native open panel:
  Copy text attachments into this workspace
  Choose up to 32 local UTF-8 text files…
  [Cancel] [Copy Attachments]

Composer after copy:
  [doc] notes.md
        1842 bytes                                      [x]
  [doc!] Unavailable attachment
         Unavailable · <UUID>                           [x]
  (+) [message text____________________________________] [↑]

During copy:
  [spinner] Copying selected text files…
```

### File selection and copy contract

- Native `NSOpenPanel`, multiple files, files only, UTType text filter, aliases not
  resolved. The app reads only explicit returned URLs; it never scans the home directory.
- Limits: 32 ordered unique files/references, 10 MiB each, 25 MiB total.
- Accepted content is strict UTF-8 plain text; tab/CR/LF are allowed, other control
  characters are rejected. Common text/code extensions and selected extensionless text
  names are accepted; known binary/image/archive/office extensions are rejected.
- Names must be safe, nonempty, no `/` or `\`, no control characters, at most 255 UTF-8
  bytes at the file-ingress layer.
- File descriptor uses `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`; final object must be a regular
  file. Before/after device/inode/size/mtime/ctime must match.
- Security-scoped access is balanced for the duration of the read. Original absolute path
  or bookmark is not persisted.
- The selected conversation is frozen at chooser start; navigation does not retarget files.
- Exact bytes, metadata, draft reference and SHA-256 are committed to Core Data through the
  sole versioned draft writer. A failed batch creates no ghost references/content.
- Once selection is accepted, quit/reconnect waits for read/save completion. An unaccepted
  chooser is cancelled.

### Chip behavior

- Draft chips show original name and exact byte count; remove control deletes the draft
  reference and schedules save.
- Chips and managed content survive original-file deletion and app restart.
- Transcript chips are read-only metadata. Rendering never fetches file bodies.
- Missing metadata becomes a per-file “Unavailable attachment” chip instead of hiding the
  reference or converting the message to empty.
- Removing a draft reference does not collect bytes still referenced by a message.

### Permission and privacy boundary

- Durable app has user-selected read-write entitlement; this source contract does not prove
  a real signed sandbox grant on every host.
- No binary/images, upload preview, arbitrary directory, symlink target or credential-file
  discovery is supported by this attachment path.
- Sample mode pressing `+` shows a notice and reads nothing.

### Accessibility

- Attach button says “Attach text files.”
- Chip announces name, bytes and stable ID; unavailable chip announces status and ID.
- Remove button names the attachment.

### Evidence

- Composer chips/progress: `WorkspaceView.swift:552-585`
- Chip component: `AttachmentViews.swift:4-74,252-270`
- Open panel and reader: `AttachmentFileImporter.swift:7-240`
- App staging/removal: `AttachmentWorkspace.swift:36-177`
- Limits/data validation: `Packages/WorkspaceCore/Sources/WorkspaceCore/Attachment.swift:4-38,63-131`
- Tests: `AttachmentFileImporterTests.swift`; `AttachmentPresentationTests.swift:9-128`;
  `AttachmentWorkspaceTests.swift:9-520`
- Detailed contract: `docs/ATTACHMENTS.md`

---

## W11 — Transmission consent sheet

**Status:** Implemented. It is mandatory for any request carrying files, every multi-target
round, and every mention-routed send including a single mentioned recipient.

**Entry:** Send a draft/retry whose prepared plan includes attachments, multiple group
targets or mention routing.

**Exit:** Cancel with zero provider effect, or confirm Send and wait for success/error.

```text
+--------------------------------------------------------------+
| Send group round? / Send text attachments?                    |
| Review ordered recipients and exact destination…              |
|--------------------------------------------------------------|
| Destination                                                  |
|   Conversation     Project team                               |
|   Ordered recipients · 2 separate requests                   |
|     1. Research Partner                                      |
|     2. Writing Partner                                       |
|   API root         https://provider.example/v1               |
|   Model            model-id                                   |
|                                                              |
| Context                                                      |
|   Same frozen pre-round context of N messages…                |
|                                                              |
| Text attachments · N · M bytes                               |
|   notes.md · 1842 bytes · ID · SHA-256                       |
|                                                              |
| Provider privacy terms and charges apply…                     |
|--------------------------------------------------------------|
| [error, if any]                                               |
| [Cancel]                                   [spinner] [Send]   |
+--------------------------------------------------------------+
```

### Disclosure contract

- Titles differ: “Send text attachments?” for a single send; “Send group round?” for a
  group round.
- Names exact conversation, target bot or ordered targets, number of separate requests,
  API root and model.
- Round context explains all requests share frozen context and later recipients do not see
  prior same-round replies. It states failure/Stop behavior.
- Mention rounds say recipients came from mentions and UUID bindings are not sent.
- If files are involved, every included file from draft, recent context or explicit older
  reply is listed with name, bytes, stable ID and SHA-256.
- Warns that attachment content is untrusted user content, sending shares it with the
  selected provider, terms/charges apply and a sent request cannot be unsent.
- Sheet is fixed `520×560`, scrolls its disclosure body, keeps action buttons outside the
  scroll area and disables interactive dismissal.

### Consent integrity

- Plan preparation reads neither credential nor network and stores no file body in the
  presentation target.
- Cancel closes the sheet, restores composer focus and makes no credential/provider call.
- Send synchronously claims the operation to defeat double-clicks.
- Before credential access it revalidates workspace context, conversation, provider,
  target order/mention snapshot, draft version and transmission fingerprint.
- Drift keeps the sheet open with a sanitized error and requires a new review.
- Retry with files repeats this exact consent flow.
- Successful send clears the reviewed draft only if the local draft version still matches.

### Accessibility

- Destination values are selectable and explicitly labelled.
- Every recipient is numbered and includes full identity in its accessibility label/help.
- File identity/hash are selectable; SHA-256 receives an explicit label.
- Cancel/Send/error have stable identifiers. Sending progress is visible.

### Evidence

- Sheet presentation: `AttachmentViews.swift:76-250`
- Planning/routing: `AttachmentWorkspace.swift:232-321`
- Cancel/confirm/drift: `AttachmentWorkspace.swift:324-380`
- Tests: `AttachmentWorkspaceTests.swift:326-466`;
  `ProviderWorkspaceTests.swift:455-668`; `MentionWorkspaceTests.swift:19-221`
- Contracts: `docs/ATTACHMENTS.md:81-120`; `docs/GROUP-ROUNDS.md`;
  `docs/GROUP-MENTIONS.md`

---

## W12 — Streaming, failed, cancelled and retry status

**Status:** Implemented through the provider core; offline fixtures cover deterministic
lifecycle logic. Broad live compatibility is not claimed.

**Entry:** Confirm or directly send a valid durable draft; reopen a conversation containing
a non-completed generation; encounter provider failure/cancellation/interruption.

**Exit:** Completion removes the status row; Stop reaches terminal cancelled; Retry creates
a new attempt linked to the same user message.

```text
[user message]

Research Partner · Queued / Connecting / Streaming         [Stop]
[partial assistant bubble grows above or beside status]

Failure:
Research Partner · Failed                                  [Retry]
<sanitized error>

Round:
Research Partner · Completed
Writing Partner · Streaming                           [Stop round]
Coordinator · Queued                                  [Stop round]
```

### State and action contract

```text
draft -> persisting -> queued -> connecting -> streaming -> completed
                        |          |              |
                        +----------+--------------+-> failed
                                   +----------------> cancelled

nonterminal at app restart -> interrupted
failed/cancelled/interrupted -> explicit Retry -> new attempt
```

- Status rows render for generations whose state is not completed.
- Speaker label uses immutable target speaker snapshot, current matching bot, persisted
  assistant snapshot, then “Deleted bot.”
- Stop is available only while nonterminal. In a round it stops the whole remaining round.
- Terminal non-routine generations offer Retry. Routine generations state that retry is
  unavailable here.
- Retry uses the currently selected provider, preserves original user message and previous
  partial text, and creates a new attempt. Failed round member waits for siblings to finish
  before retry becomes valid.
- Retry with files returns to W11. HTTP/provider failures do not auto-retry.
- While an action is pending, affected status controls disable to avoid duplicates.
- Error rendering uses sanitized provider/storage messages; credentials must not appear.

### Network boundary

- User message plus queued generation(s) persist atomically before transport.
- Persistence failure keeps draft and makes zero transport calls.
- Per-conversation concurrency is one active generation; coordinator global maximum is
  three. Queued contexts are frozen and do not absorb replies completed later.
- Stop cannot retract bytes already received by a provider. Late events for cancelled/stale
  attempts are rejected.

### Evidence

- UI: `WorkspaceView.swift:503-512,774-821`
- Coordinator presentation: `ProviderWorkspace.swift:84-130,184-275`
- No-provider/send orchestration: `PersistentWorkspace.swift:285-309`
- Tests: `ProviderWorkspaceTests.swift:212-274,306-420,455-668`;
  core `Packages/WorkspaceCore/Tests/WorkspaceCoreTests/GenerationTests.swift`, `GroupRoundCoordinatorTests.swift`
- Provider limits: `docs/PROVIDER-CORE.md:61-106,108-155`

---

## W13 — Disconnected computer inspector

**Status:** The disconnected presentation is implemented. A live computer, graphical desktop,
terminal viewer or remote-control adapter is **planned/not implemented** in
this app.

**Entry:** Show conversation details on a window wide enough for the inspector.

**Exit:** Inspector hide button, conversation-header details toggle, narrow window or picker.

```text
+-------------------------------+
|                    [gear] [>>]|
| [pencil] Edit Bot profile     |
| Bot description / group names |
|                               |
| +---------------------------+ |
| |      [desktop icon]       | |
| |   No computer connected   | |
| | No live computer service  | |
| | configured for workspace. | |
| +---------------------------+ |
|        Bot's screen           |
|                               |
| Routines                  [+] |
| …                             |
+-------------------------------+
```

### Exact current behavior

- Top controls open Settings and hide details.
- Edit profile/member control opens W16/W17.
- Direct inspector may show Bot description; group inspector lists current member names.
- Computer panel is a static, explicit disconnected state with no wallpaper, frame, URL,
  WebSocket, reconnect button, keyboard capture or pointer capture.
- The caption uses `<Bot name>'s screen` or `Group's screen`; it does **not** assert that a
  screen exists or is streaming.
- Routines list appears below the computer panel; routine functionality belongs to its own
  contract.

### Permission/network boundary

- Rendering W13 makes no request to a remote computer or terminal service.
- No private infrastructure configuration or deployment details are included here.
- Adding a terminal or desktop requires a separate adapter contract covering endpoint
  ownership, authentication, view-vs-control permission, transport security, lifecycle,
  accessibility and disconnect behavior. It must not be smuggled in as an iframe or static
  screenshot labelled live.

### Accessibility

- Settings/hide/edit icon controls have labels and identifiers.
- Disconnected panel has `computer-disconnected` identifier and readable text.

### Evidence

- `WorkspaceView.swift:927-982`
- Visibility/layout: `WorkspaceLayout.swift:9-19`
- Required honest state: `docs/NATIVE-REWRITE-CONTRACT.md:65,69-71,107-112,202-215`
- Product boundary: `README.md:7-13`
- Acceptance target: `docs/NATIVE-REWRITE-CONTRACT.md:245-246`

---

## W14 — Marketplace/local templates

**Status:** Implemented local catalog. It is not an online marketplace, plugin installer,
credential grant or live automation registry.

**Entry:** Sidebar → Marketplace.

**Exit:** Close `x`, Escape, or add a template (which creates/selects a Bot and closes sheet).

```text
+----------------------------------------------+
| Marketplace                              [x] |
| Start with a focused teammate                |
| Local templates. Installing one creates…     |
|                                              |
| [avatar] Research Partner              [Add] |
|          Find sources, compare options…      |
| -------------------------------------------- |
| [avatar] Writing Partner               [Add] |
|          Turn rough notes into clear drafts… |
| -------------------------------------------- |
| [avatar] Project Coordinator           [Add] |
|          Organize next steps…                 |
+----------------------------------------------+
```

### Contract

- Fixed local entries: Research Partner, Writing Partner, Project Coordinator.
- Each contains a name, description, original avatar color and shape.
- Add reuses normal create-Bot validation/persistence, creates an independent Bot/direct
  conversation and selects it.
- It does not attach provider credentials, routines, messages or computer access.
- The sheet truthfully states that the result is a separate Bot, not live automation.
- UI is implemented, but the full acceptance test “install the same template twice and
  prove independent IDs/conversations and no inherited credentials/jobs” is not named as a
  dedicated Marketplace UI test. Generic Bot creation does generate fresh identities.

### Accessibility

- Close button names the sheet.
- Each Add button announces “Add <template name>.”
- Avatar is decorative alongside visible name/description.

### Evidence

- Sidebar entry: `WorkspaceView.swift:204-226`
- Panel dispatch: `PrototypePanel.swift:14-44`
- Catalog/actions: `PrototypePanel.swift:119-157`
- Create identity: `Models.swift:331-345`; `PersistentWorkspace.swift:228-244`
- Generic identity tests: `PreviewWorkspaceTests.swift:66-80`
- Planned acceptance: `docs/NATIVE-REWRITE-CONTRACT.md:66-67,245`

---

## W15 — Account/display-name sheet

**Status:** Implemented. This is a local display-name editor, not account authentication,
cloud profile, billing or provider identity.

**Entry:** Bottom sidebar account row.

**Exit:** Cancel, close `x`, Escape, or Save.

```text
+------------------------------------------+
| Your profile                         [x] |
| [Display name__________________________] |
| Your display name is saved on this Mac. |
|                                          |
|                         [Cancel] [Save]  |
+------------------------------------------+
```

### Contract

- Field initializes from the current workspace display name when the sheet appears.
- Save trims whitespace and requires 1…80 characters. Invalid input shows the shared name
  validation error and leaves sheet open.
- Durable mode writes to app UserDefaults key `workspace.displayName`; it is separate from
  provider credentials and Core Data workspace export.
- Sample mode changes only the preview session value.
- Cancel/close performs no write.
- No avatar upload, email, sign-in, subscription, logout or remote sync exists here.

### Accessibility

- Visible field label is currently its placeholder; Cancel/Save are native labelled
  controls. The sidebar account control has identifier `profile`.
- A fuller form-label/VoiceOver pass remains part of the global accessibility gap.

### Evidence

- Sidebar entry: `WorkspaceView.swift:217-236`
- Sheet: `PrototypePanel.swift:14-44,193-216`
- Save: `PersistentWorkspace.swift:311-314`
- Load/fallback: `PersistentWorkspace.swift:62-64`

---

## W16 — Edit Bot sheet

**Status:** Implemented with detached buffer, conflict handling and durable persistence.

**Entry:** Header edit, inspector edit, or direct-row context menu.

**Exit:** Save success, clean Cancel/close/Escape, or confirmed dirty discard.

```text
+----------------------------------------------------+
| Edit Bot                                       [x] |
| [large avatar]  Avatar preview                      |
|                 Choose an original shape/color…     |
| Name                                               |
| [Name____________________________________________] |
| Description                                        |
| [multi-line editor_______________________________] |
| 42 / 8,000 characters                              |
| Color  [o][o][o][o][o]                             |
| Shape  [Circle v]                                  |
| [validation / save error] [Reload latest]          |
| Existing messages keep recorded speaker names…    |
|----------------------------------------------------|
|                                  [Cancel] [Save]   |
+----------------------------------------------------+
```

### Editable fields and validation

- Name: trimmed 1…80 characters.
- Description: at most 8,000 characters; live count displayed.
- Color: fixed original palette with selected trait/checkmark.
- Shape: circle, square, drop or capsule.
- Save enables only after load, when dirty, not saving/loading, and validation succeeds.

### Detached edit/concurrency contract

- Sheet target is stable Bot UUID, independent of current sidebar selection. Navigation
  cannot redirect Save.
- Only editable profile fields participate in conflict comparison/write. Hidden state,
  provider association, routine ownership, creation identity, drafts and messages are not
  overwritten by the long-lived form.
- Durable save uses expected snapshot vs replacement. Stale edit fails visibly and offers
  “Reload latest”; dirty reload asks before discarding form edits.
- Save claims ownership synchronously. Quit/close waits for an accepted save.
- If the user edits again while Save is in flight, the accepted version becomes baseline,
  newer fields remain open and message says “Saved. Newer edits remain in this form.”
- Dirty Cancel/close/Escape opens “Discard unsaved profile changes?” with Keep Editing and
  destructive Discard Changes.
- Successful dismissal returns focus to composer.
- Existing messages retain immutable recorded speaker names after rename.

### Network/permission boundary

- Profile save is repository-only and makes no provider request or credential read.
- No image/file picker is used for avatars; shapes/colors are app-drawn.

### Accessibility

- Title is a header; close/save/cancel/reload/validation have labels and identifiers.
- Colors announce name and selected trait; shape picker is labelled.
- The sheet disables interactive swipe/dismiss and lets explicit dirty-state logic decide.

### Evidence

- Controller/validation/concurrency: `ProfileEditorView.swift:18-339`
- View: `ProfileEditorView.swift:350-508`
- Repository mutation: `EditingWorkspace.swift:23-135`
- Tests: `ProfileEditorTests.swift:9-192`; `ProfileWorkspaceTests.swift:28-267`

---

## W17 — Edit Group sheet

**Status:** Implemented with ordered membership and stable identity.

**Entry:** Header edit, inspector edit, or group-row context menu.

**Exit:** Same Save/Cancel/dirty-discard rules as W16.

```text
+----------------------------------------------------+
| Edit Group                                     [x] |
| Group name                                         |
| [Project team___________________________________] |
| Members                              [Add member v] |
| [avatar] Research Partner              [↑][↓] [x]  |
| [avatar] Hidden member [Hidden]         [↑][↓] [x]  |
| [avatar] Writing Partner               [↑][↓] [x]  |
| Keep 2–6 different bots…                            |
| [validation / conflict] [Reload latest]             |
| Existing history/queued attribution is unchanged…  |
|----------------------------------------------------|
|                                  [Cancel] [Save]   |
+----------------------------------------------------+
```

### Membership contract

- Group name trims to 1…80 characters.
- Ordered list must contain 2…6 unique existing Bot UUIDs.
- Add menu offers non-hidden bots not already in group and disables at six/no candidates.
- Up/down preserves explicit future reply order. Remove does not delete the Bot.
- A hidden Bot already in the group may remain and is visibly tagged Hidden. If removed,
  it cannot be re-added while hidden.
- Missing members cause explicit validation asking to reload.
- Save affects future replies only. Existing speaker snapshots, transcript and queued/in-
  flight replies are not rewritten.
- Manually selected future reply targets removed from membership are cleared/filtered.
- Conflict/reload/in-flight Save/dirty-dismiss behavior matches W16.

### Persistence/network boundary

- Durable edit is one optimistic repository mutation against the expected group profile.
- It performs no provider request. A group membership edit does not start bot-to-bot work.
- Removing members does not delete their direct conversations or identities.

### Accessibility

- Every move/remove action names the member and direction/action.
- Hidden status is visible text.
- Group name/member container/add menu/save errors expose identifiers.

### Evidence

- Controller member rules: `ProfileEditorView.swift:95-117,185-205,321-337`
- Group UI: `ProfileEditorView.swift:510-576`
- Save and selected-target repair: `EditingWorkspace.swift:83-135`
- Tests: `ProfileEditorTests.swift:149-191`;
  `ProfileWorkspaceTests.swift:78-128,152-174`

---

## W18 — Degraded group requiring membership repair

**Status:** Implemented. This state can result from confirmed Bot deletion or stale/missing
membership. History and drafts remain readable.

**Entry:** Open a group with fewer than two currently available members.

**Exit:** Edit Group and save at least two valid members, or navigate away.

```text
+------------------------------------------------------------------+
| [group] Team                                  [edit] [routines]  |
|------------------------------------------------------------------|
| preserved transcript and draft                                     |
|------------------------------------------------------------------|
| Group needs repair                                                |
| History and drafts are kept. Choose at least two available…       |
| [Edit Group…]                                                     |
|                                                                  |
| provider/target/composer remains visible, Send disabled           |
+------------------------------------------------------------------+
```

### Contract

- Repair warning appears above provider controls and composer.
- “Edit Group…” opens W17. Send button disables and the service repeats the guard, keeping
  draft intact with explicit notice.
- Existing group history, draft and recorded speaker names are retained.
- This state does not fabricate a replacement member or silently collapse group semantics
  into direct chat.
- The inspector may list zero/one current member name; computer remains W13 disconnected.

### Evidence

- UI/send gate: `WorkspaceView.swift:515-527,613-620`
- Service gate: `PersistentWorkspace.swift:285-299`
- Repair predicate: `BotDeletionWorkspace.swift:18-24`
- Edit recovery: W17 evidence above
- Tests: `BotDeletionWorkspaceTests.swift`; deletion smoke limits in
  `docs/BOT-DELETION.md`

---

## W19 — Global opening/saving/storage-error overlays

**Status:** Implemented.

**Entry:** Durable open/close in progress, or repository/draft/search/provider-refresh
storage error.

**Exit:** Operation completes, retry succeeds, or the user closes/quits through guarded flow.

```text
                  +--------------------------------+
                  | Opening local workspace…       |
                  |              or                |
                  | Saving workspace…              |
                  +--------------------------------+

                  +--------------------------------+
                  | <sanitized storage error>      |
                  | Your data has not been reset.  |
                  | Unsaved drafts remain…         |
                  | [Retry saving drafts]           |
                  |        or                       |
                  | [Retry opening workspace]       |
                  +--------------------------------+
```

### Contract

- Root content disables during open/close.
- Loading/saving overlay appears at top with progress indication.
- Error text is warning-colored and states that data was not reset and in-window drafts
  remain.
- If repository exists, action is “Retry saving drafts.” If opening failed before repository
  attachment, action is “Retry opening workspace.”
- Retry failure updates the same visible error; it does not seed demo content or announce
  success.
- Close failure reactivates the app/store, preserves visible error and does not silently
  replay queued provider work.
- Read-status failure is separate and appears within conversation header area as described
  in W03.

### Accessibility and gaps

- Progress/error text is visible but this document does not claim tested live-region
  announcements or focus movement into overlays.
- Error content must remain sanitized; provider credentials/file bodies must not appear.

### Evidence

- Root overlays: `WorkspaceView.swift:65-94`
- Open and close flows: `NativeShellApp.swift:90-95,162-228`
- Draft writer/recovery: `PersistentWorkspace.swift:173-225`
- Tests: `PersistentWorkspaceTests.swift`; `ProviderWorkspaceTests.swift:693-736`;
  `ConversationActivityWorkspaceTests.swift:135-193`

---

## Cross-screen state flows

### Conversation selection and draft safety

```text
row activation
  -> validate row still exists
  -> flush all accepted dirty drafts
       `-- failure -> keep current selection + W19 error
  -> invalidate stale selection/read viewport
  -> set selected conversation; close picker; clear notice
  -> load latest 100 messages + reply/attachment metadata
  -> focus composer
```

Evidence: `Models.swift:285-308`; `PersistentWorkspace.swift:119-133,173-225`.

### Direct send

```text
Return / Send
  -> block empty text+files, busy, missing provider or damaged group
  -> capture exact conversation, provider, target, draft version, reply, files
  -> flush draft
  -> if any files/context files: W11
     else: submit
  -> atomically persist user message + queued generation + matching-draft clear
  -> queue/connect/stream
  -> completed OR visible failed/cancelled
```

### Manual group round

```text
choose ordered targets
  -> 1 target + no files: direct submission path
  -> 2...6 targets: prepare aggregate consent
       -> W11 ordered review
       -> revalidate exact order/destination/draft/context
       -> one user message + N queued generations
       -> N separate ordered requests, frozen common context
       -> attributed member replies/statuses
```

### Mention-routed group send

```text
typed or picker-inserted @members
  -> parse local draft
  -> any issue: inline error + Send disabled
  -> valid: deduplicate in first-occurrence order
  -> replace manual targets in read-only preview
  -> always W11 (even 1 recipient)
  -> remove local UUID binding suffixes for transcript/provider
  -> send bounded round
```

### Reply lifecycle

```text
Reply under message
  -> validate same-conversation non-event parent
  -> save replyToID beside existing draft
  -> preview: loading -> available | unavailable
  -> click available -> load older pages until original exists -> center original
  -> send -> validate parent and include once in context
  -> matching draft/reference clears; newer edits remain
```

### Attachment lifecycle

```text
Attach +
  -> native user-selected files only
  -> bounded validation/read with scoped permission
  -> atomic managed copy + draft references
  -> removable persistent chips
  -> Send -> content/destination plan without credential
  -> W11
  -> revalidate exact bytes/hash/context/destination
  -> credential read + provider request
```

### Unread acknowledgement

```text
incoming assistant message -> persisted activity + unread count
  -> row badge (visual <=99+, a11y exact)
  -> selection alone: no acknowledgement
  -> main window active/key/visible + no transient surface
     + transcript exact latest rendered at strict bottom
     + no active generation
  -> write captured sequence
  -> refresh snapshot
  -> only then clear badge
  -> failure keeps badge + Retry read status
```

## Persistence, network and permission matrix

| UI datum/action | Persistence | Network | OS permission/security boundary |
|---|---|---|---|
| Pane width/visibility/appearance | Versioned app UserDefaults | None | No workspace/export coupling |
| Account display name | App UserDefaults in durable mode | None | Not provider/account auth |
| Bots/groups/messages/drafts/replies | Core Data workspace | None until explicit send | App sandbox Application Support |
| Search/activity/unread marker | Core Data query/mutation | None | Main-window visibility gates read acknowledgement |
| Provider selection | Session presentation state | None by selection alone | Credentials remain separate |
| Provider send | Atomic message/generation state, streamed text | Explicit configured outbound request | Keychain or explicit process-memory credential; no plaintext fallback |
| Group round | One message + N generation records | N separately disclosed requests | Aggregate consent before credential access |
| Mention UUID binding | Raw token persists only in local draft until send | UUID suffix never sent | Exact identity binding; readable text only crosses provider boundary |
| Text attachments | Exact managed bytes + metadata in Core Data | Only after W11 | Explicit native file selection and scoped read; no home scan/path retention |
| Marketplace Add | Independent Bot + direct conversation | None | Local fixed templates only |
| Inspector computer panel | Nothing | **None** | No terminal/desktop/control permission exists |

## Screenshot capture contract for the master catalog

The master screenshot catalog may map captures to `W01`–`W19`. For every mapped capture it
should record:

1. **Provenance:** private reference, current app render, isolated smoke render or real
   manual run.
2. **Mode:** durable, sample or isolated fixture.
3. **Appearance and geometry:** Dark/Light/System and content size.
4. **State injection:** synthetic data, fixture foreground, intercepted provider or real
   endpoint.
5. **What the image cannot prove:** persistence restart, physical input, VoiceOver, OS
   permission, network authenticity or computer connectivity unless independently observed.

The catalog should content-hash captures as well as naming them. Multiple capture records
can resolve to identical pixels; a distinct scenario label is not evidence of a distinct UI
state. This is especially important for W06 mention variants.

Do not use a screenshot alone to claim:

- a provider request completed;
- a credential was stored securely;
- unread state was acknowledged through real window focus;
- an attachment received a real sandbox grant;
- a group round issued multiple independent requests;
- the computer panel is live;
- a keyboard/IME/VoiceOver path works.

## Known workspace coverage gaps

- **Live computer/terminal:** W13 is disconnected by design. No remote-computer adapter
  exists in the app.
- **Physical input/a11y:** semantic labels and hosted AppKit tests exist, but full native
  mouse/keyboard/IME/VoiceOver/XCUITest flows remain open.
- **Real focus:** unread fixture injection does not replace the strict main-window focus gate.
- **Real file grants:** importer and fixture copy are tested; physical `NSOpenPanel` sandbox
  grant behavior remains manual.
- **Broad providers/signing:** offline transport fixtures and one bounded Codex diagnostic do
  not prove all providers, local routers, Keychain entitlement or distribution signing.
- **Marketplace-specific acceptance:** the local Add UI exists; a dedicated twice-install UI
  scenario is not identified in the current shell suite.
- **Account semantics:** W15 is only local display name. Any cloud account screen is absent.
- **Message menu scope:** current message rows expose Reply/Copy only. Reactions, edit,
  delete, forwarding and tool execution are absent.
- **Settings and routines:** navigation is documented here, but detailed screens are owned by
  their existing contracts (`PROVIDER-SETUP.md`, `PROVIDER-CORE.md`, `APPEARANCE.md`,
  `WORKSPACE-EXPORT.md`, `ROUTINES.md`).

## Authoritative related contracts

- [Native rewrite and acceptance](NATIVE-REWRITE-CONTRACT.md)
- [Durable workspace evidence](DURABLE-WORKSPACE.md)
- [Unread conversations](UNREAD-CONVERSATIONS.md)
- [Group rounds](GROUP-ROUNDS.md)
- [Group mentions](GROUP-MENTIONS.md)
- [Replies](REPLY-WORKFLOW.md)
- [Attachments](ATTACHMENTS.md)
- [Provider core](PROVIDER-CORE.md)
- [Appearance/layout](APPEARANCE.md)
- [Routines](ROUTINES.md)
- [Bot deletion and group repair](BOT-DELETION.md)
