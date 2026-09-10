# Management screens and feature contract

This document specifies the native macOS management surfaces for creating and editing
bots/groups, deleting bots, configuring providers and appearance, managing routines,
and exporting the workspace. It describes the current SwiftUI/AppKit implementation,
not a speculative redesign.

Use the stable IDs `M01`–`M20` when linking screenshots, QA evidence, issues, or future
screen-atlas entries. Screenshot coverage is tracked by those IDs; this file does not
invent screenshot filenames.

Evidence paths are abbreviated consistently: native source/test filenames resolve under
`Prototypes/NativeShell/Sources/NativeShell/` and
`Prototypes/NativeShell/Tests/NativeShellTests/`; core source/test filenames resolve
under `Packages/WorkspaceCore/Sources/WorkspaceCore/` and
`Packages/WorkspaceCore/Tests/WorkspaceCoreTests/`. Every `file:line-range` citation is
an implementation or automated-test location, not screenshot proof.

## Status vocabulary

| Label | Meaning |
|---|---|
| **Implemented** | The durable native app has the described UI and backing behavior. |
| **Sample-only** | The in-memory preview has a reduced behavior; it does not prove durable storage or network execution. |
| **OS-owned** | macOS presents the surface (`NSOpenPanel`, `NSSavePanel`, or overwrite confirmation). App layout and wording outside the configured panel properties may vary by OS release. |
| **Offline verified** | Automated tests or synthetic smoke fixtures exercise the behavior without a real provider or user workspace. |
| **Live unverified** | The path is implemented, but this repository does not prove a real account, endpoint, paid request, Keychain signing environment, or physical assistive-technology flow. |
| **Not implemented** | The UI may disclose the boundary, but the capability is absent. |

## Management navigation map

```text
Workspace
├─ File → New Chat (⌘N) ──────────────── M01
│  ├─ choose existing bot → direct chat
│  ├─ Create new Bot ─────────────────── M03
│  └─ Create group chat ──────────────── M02
├─ Edit Bot… / Edit Group… ───────────── M04 / M05
│  ├─ dirty Cancel/Escape ────────────── M06
│  └─ stale/save error → Reload latest ─ M07
├─ Delete Bot… ───────────────────────── M08
│  └─ degraded group repair banner ───── M09 → M05
├─ Settings… (⌘,) ────────────────────── M10
│  ├─ provider template replacement ──── M11
│  ├─ API-key configuration ──────────── M12
│  ├─ local model discovery ──────────── M13
│  ├─ Codex login configuration ──────── M14
│  │  └─ auth.json file picker ───────── M15 (OS-owned)
│  ├─ appearance/layout ──────────────── M16
│  └─ workspace export ───────────────── M17
│     ├─ JSON Save Panel ─────────────── M18 (OS-owned)
│     └─ exporting/result state ───────── M19
└─ Routines menu / inspector +
   ├─ new or edit routine ────────────── M20A
   ├─ routine detail/history ─────────── M20B
   ├─ Run Now consent ────────────────── M20C
   └─ delete routine consent ─────────── M20D
```

`M20A`–`M20D` are sub-surfaces of the stable routine family `M20`, not new top-level
IDs. This keeps the requested management catalog at `M01`–`M20` while allowing QA to
name each routine state precisely.

## Global management invariants

1. The durable app persists workspace records in its local repository. The preview
   path uses in-memory fixtures and must be labeled as such.
2. A detached profile/routine form is bound to a stable identity. Navigating to another
   conversation cannot retarget an accepted save.
3. Accepted profile, routine, deletion, and export operations are joined by close/quit
   where required; close must not silently cancel a committed operation.
4. Entered provider credentials are replacement-only. A saved secret is never loaded
   back into SwiftUI form state.
5. Network transmission is explicit. Saving provider metadata is not a connection test.
   Saving a paused routine sends nothing. Run Now and automatic routines require their
   own disclosed consent.
6. Management failures show sanitized descriptions. Filesystem paths, raw provider
   responses, keys, OAuth tokens, and private infrastructure values must not be copied
   into screenshots or diagnostics.
7. Settings is a separate resizable native window in durable mode. In sample mode,
   the older compact prototype panel is used instead.

Primary implementation evidence:
`Prototypes/NativeShell/Sources/NativeShell/WorkspaceView.swift:22-64`,
`Prototypes/NativeShell/Sources/NativeShell/NativeShellApp.swift:1297-1379`, and
`Prototypes/NativeShell/Sources/NativeShell/NativeShellApp.swift:1386-1450`.

---

## M01 — New Chat recipient picker

**Status:** Implemented; durable and sample presentation share this SwiftUI surface.
Creation/persistence behavior differs after selection. Offline fixture coverage exists;
physical keyboard/VoiceOver navigation is not automated.

### Entry and exit

- Enter from **File → New Chat** (`⌘N`) or the workspace new-chat control.
- Entry clears the query, selected group recipients, highlight index, and notice.
- Exit by selecting an existing direct-chat bot, opening M02/M03, clicking the close
  button, or pressing Escape.
- Selecting a bot only opens an already existing direct conversation; it does not
  create duplicate direct conversations.

```text
┌──────────────────────────────────────────────────────────────┐
│ To: [ Search or create Bots________________________ ]   (×)  │
├──────────────────────────────────────────────────────────────┤
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ (+)  Create new Bot                                     │ │
│ │ (👥) Create group chat                                  │ │
│ │ ●    Bot Alpha                              New chat     │ │
│ │ ■    Bot Beta                                            │ │
│ └──────────────────────────────────────────────────────────┘ │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Fields and actions

| Element | Contract |
|---|---|
| `To:` query | Case-insensitive localized name filtering; changing it resets highlight to the first result. |
| **Create new Bot** | Opens M03. |
| **Create group chat** | Switches in place to M02. |
| Bot result | Opens that bot's existing direct conversation. |
| Close icon | Closes picker without changing workspace content. |
| Empty result | Shows **No matching bots**. |

### Keyboard and accessibility

- Query receives focus on appearance.
- Up/Down changes the highlighted result without wrapping.
- Return commits the highlighted bot only when a result exists.
- Escape closes the picker at workspace level.
- Query identifier: `recipient-query`.
- Close accessibility label: **Cancel new chat**.
- Each result announces **Chat with _bot name_**.

### Persistence, network, and failure behavior

- Opening/filtering performs no network request and no write.
- Durable conversation selection flushes pending drafts before loading the selected
  conversation; a storage error leaves the error visible rather than resetting data.
- There is no picker-specific retry UI; workspace storage recovery remains global.

**Evidence:** `RecipientPickerView.swift:9-19,42-76,108-137`;
`Models.swift:278-329`; `NativeShellApp.swift:1306-1320,1346-1347`.
Core selection/create persistence is covered indirectly by
`PersistentWorkspaceTests.swift:17-43`. No dedicated UI automation test asserts the
Up/Down/Return route.

---

## M02 — Create Group picker

**Status:** Implemented; durable creation is persisted, sample creation is in memory.
Offline validation and reopen coverage exist.

### Entry and exit

- Enter from M01 → **Create group chat**.
- Successful creation selects the new group conversation and closes the picker.
- Close icon or Escape exits without creating a group.

```text
┌──────────────────────────────────────────────────────────────┐
│ To: [ Search or create Bots________________________ ]   (×)  │
├──────────────────────────────────────────────────────────────┤
│ [● Alpha ×] [■ Beta ×]                       selected chips  │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ ◆ Gamma                              Add to group chat   │ │
│ │ ● Delta                                                  │ │
│ └──────────────────────────────────────────────────────────┘ │
│                                                              │
│ [ Group name: New group chat________________ ] [Create group]│
│ Choose two to six bots. This group is saved on your Mac.     │
└──────────────────────────────────────────────────────────────┘
```

### Fields, actions, and validation

| Element | Contract |
|---|---|
| Selected chips | Preserve user selection order; each chip has a named Remove action. |
| Result row | Adds the bot, clears the query, and resets highlight. Already selected and hidden bots are excluded. |
| Maximum | Six bots. Remaining rows disable at six and empty text becomes **Six bots selected**. |
| Minimum | **Create group** remains disabled until two bots are selected. |
| Group name | Default **New group chat**; after trimming must be 1–80 characters. |
| Membership | Must contain 2–6 distinct, currently available, non-hidden bot IDs. |
| Create | Asynchronous single save; all controls disable through shared `isSaving`. |

### Failure and persistence behavior

- A validation/repository error appears under the form in warning color; the current
  name and selection remain available for correction.
- Durable mode writes the group, refreshes the projection, and selects it.
- Sample mode adds an in-memory group only and labels it **local previews**.
- Group creation performs no provider call and requires no credential or consent.

### Keyboard and accessibility

- Up/Down/Return work as in M01.
- `⌘Return` activates **Create group** when enabled.
- IDs: `group-name`, `create-group`; result labels say **Add _name_**; chip remove
  actions say **Remove _name_**.

**Evidence:** `RecipientPickerView.swift:21-40,47-105`;
`Models.swift:318-362`; `PersistentWorkspace.swift:246-253`.
Validation tests: `PreviewWorkspaceTests.swift:82-163`. Durable reopen test:
`PersistentWorkspaceTests.swift:17-43`.

---

## M03 — Create a Bot

**Status:** Implemented. Durable mode saves locally; sample mode creates an in-memory
preview bot. The surface is a SwiftUI sheet (`PrototypePanel`).

### Entry and exit

- Enter from M01 → **Create new Bot**, or a workspace first-bot action.
- **Create Bot** creates a bot plus its one-member direct conversation, selects that
  conversation, and closes the sheet.
- **Cancel**, Escape, or the close icon closes without saving.
- **Current limitation:** this form does not track dirty state and does not ask before
  discarding unsaved fields. This differs from M04/M05/M20A and is an implementation
  gap, not an implied feature.

```text
┌──────────────────────── Create a Bot ────────────────────────┐
│                                                    (×)       │
│                         [avatar]                             │
│ [ Bot name_______________________________________________ ]  │
│ [ What should this Bot help with?________________________ ]  │
│ [________________________________________________________ ]  │
│ Shape: [ Circle ▾ ]                                         │
│ Color: ●  ●  ●  ●  ●  ●                                    │
│ This bot is saved on this Mac. Choose a provider before…     │
│                                  [Cancel] [Create Bot]       │
└──────────────────────────────────────────────────────────────┘
```

### Fields, actions, and validation

| Element | Contract |
|---|---|
| Avatar preview | Updates from selected shape/color. |
| Bot name | Required in the UI; trimmed persisted value must be 1–80 characters. |
| Description | Multi-line visual field; core validation caps it at 8,000 characters. The create sheet has no live counter. |
| Shape | Current `AvatarKind.allCases`; presentation names are capitalized. |
| Color | Supported palette: green, magenta, gray, violet, blue, orange. Selected choice is announced. |
| Create Bot | Default action; disabled only for a whitespace-empty name, while core validation handles other invalid input. |

### Persistence, network, and failure behavior

- Durable mode first commits to the repository, then refreshes/selects; a failed write
  must not create a ghost bot in the projection.
- No provider is assigned automatically. No computer/desktop or provider request is
  started.
- Failure text remains in the sheet and the form remains editable after `isSaving`
  clears.

### Keyboard and accessibility

- Cancel is the cancel action; Create Bot is the default action.
- IDs: `bot-name`, `create-bot`.
- Color buttons expose `_color_ avatar` and selected traits.
- There is no explicit focus-state contract in this sheet.

**Evidence:** `PrototypePanel.swift:3-44,46-88,218-227`;
`Models.swift:331-345`; `PersistentWorkspace.swift:228-244`;
`Domain.swift:306-331`. Tests: `PreviewWorkspaceTests.swift:29-80` and
`PersistentWorkspaceTests.swift:123-145`.

---

## M04 — Edit Bot

**Status:** Implemented detached editor; durable CAS save and in-memory preview save.
Offline tests cover validation, concurrency, reopen, and draft preservation.

### Entry and exit

- Enter from the conversation header pencil, inspector **Edit Bot profile**, or direct
  conversation context menu **Edit Bot…**.
- The captured bot ID, not the later current selection, owns load/save.
- Clean Cancel/Escape/close exits immediately. Dirty exit routes to M06.
- Successful save dismisses only when no newer edits appeared during the accepted save.

```text
┌────────────────────────── Edit Bot ──────────────────────────┐
│                                                       (×)    │
│ [avatar]  Avatar preview                                    │
│           Choose an original shape and color…               │
│ Name                                                        │
│ [ Bot name_______________________________________________ ]  │
│ Description                                                 │
│ [________________________________________________________ ]  │
│ [________________________________________________________ ]  │
│                                           123 / 8,000 chars │
│ Color  ● ● ● ● ● ●                                         │
│ Shape  [ Circle ▾ ]                                         │
│ ⚠ validation/save error                     [Reload latest] │
│ Existing messages keep recorded speaker names…              │
├──────────────────────────────────────────────────────────────┤
│                               [Cancel] [Save]                │
└──────────────────────────────────────────────────────────────┘
```

### Fields and validation

- **Name:** trimmed 1–80 characters.
- **Description:** up to 8,000 characters, with live count.
- **Color:** supported palette only.
- **Shape:** supported avatar shapes only.
- Save enables only after load, when dirty, valid, not loading, and not saving.

### State and conflict behavior

| State | UI/behavior |
|---|---|
| Initial load | **Loading profile…**; form unavailable. |
| Validation failure | Inline warning with `profile-validation-error`; Save disabled. |
| Save in progress | Spinner; close/Cancel disabled; app close joins accepted save. |
| Save error/stale CAS | Sanitized error plus **Reload latest**; edits remain. |
| Edit made during save | Accepted snapshot becomes baseline; message **Saved. Newer edits remain in this form.**; sheet stays open and dirty. |
| Successful unchanged save | Projection refreshes; editor dismisses and composer focus is requested. |

Only editable profile fields participate in conflict comparison. Provider assignment,
visibility, identity, drafts, routine ownership, and streamed deltas are not overwritten.
Existing messages keep immutable speaker-name snapshots.

### Keyboard and accessibility

- First field receives focus after load.
- Escape and Cancel call the same dirty-aware path; Save is default action.
- Header has header trait.
- IDs: `profile-close`, `profile-bot-name`, `profile-bot-description`,
  `profile-bot-shape`, `profile-color-*`, `profile-cancel`, `profile-save`,
  `profile-save-error`, `profile-reload-latest`.

**Evidence:** `ProfileEditorView.swift:49-93,119-163,207-277,350-508`;
`EditingWorkspace.swift:5-21,23-135`; `WorkspaceView.swift:302-314,353-387,927-950`.
Tests: `ProfileEditorTests.swift:21-147` and `ProfileWorkspaceTests.swift:28-76,130-150,197-267`.

---

## M05 — Edit Group / repair membership

**Status:** Implemented detached editor using the same identity/concurrency shell as
M04. It also repairs zero/one-member groups left by confirmed deletion.

### Entry and exit

- Enter from header, inspector, context menu, or M09 **Edit Group…**.
- Exit and save semantics match M04/M06/M07.

```text
┌───────────────────────── Edit Group ─────────────────────────┐
│                                                       (×)    │
│ Group name                                                  │
│ [ Project crew___________________________________________ ]  │
│ Members                                      [Add member ▾] │
│ ┌──────────────────────────────────────────────────────────┐ │
│ │ ● Alpha                         [↑][↓] [remove]          │ │
│ │ ■ Legacy Bot  [Hidden]          [↑][↓] [remove]          │ │
│ │ ◆ Beta                          [↑][↓] [remove]          │ │
│ └──────────────────────────────────────────────────────────┘ │
│ Keep 2–6 different bots. Hidden existing bots may remain…    │
│ ⚠ validation/save error                     [Reload latest] │
├──────────────────────────────────────────────────────────────┤
│                               [Cancel] [Save]                │
└──────────────────────────────────────────────────────────────┘
```

### Fields, actions, and validation

| Element | Contract |
|---|---|
| Group name | Trimmed 1–80 characters. |
| Member order | Explicit and persisted; Up/Down buttons reorder future reply membership. |
| Add member | Lists visible, not-already-selected bots; disables at six or when none remain. |
| Remove | Removes selected member. A hidden member removed in this editing session cannot be re-added. |
| Membership save | Requires 2–6 distinct available bots. Exact degraded 0/1-member persisted groups may load, but Save stays invalid until repaired. |
| Hidden legacy member | May remain and is labeled **Hidden**. It cannot be newly added. |
| Unavailable member | Displays **Unavailable bot** and blocks save with **Reload the latest group** guidance. |

### Effects and concurrency

- Membership changes affect future replies only. Existing group messages, immutable
  speaker names, drafts, and in-flight reply attribution remain.
- Removed bots are cleared from future explicit composer targets.
- A stale baseline cannot overwrite a newer group edit.
- Navigation cannot redirect the save to another group.

### Keyboard and accessibility

- Group name receives focus after load; Escape/Cancel/default Save match M04.
- Member container and every move/remove action have stable accessibility identifiers
  and descriptive labels.

**Evidence:** `ProfileEditorView.swift:95-117,185-205,278-337,510-576`;
`EditingWorkspace.swift:115-134`; `Domain.swift:333-341`.
Tests: `ProfileEditorTests.swift:149-179`; `ProfileWorkspaceTests.swift:78-128,152-174`;
degraded repair persistence: `BotDeletionWorkspaceTests.swift:138-187,246-262`.

---

## M06 — Unsaved profile discard confirmation

**Status:** Implemented SwiftUI alert inside M04/M05, plus an AppKit close/quit alert.

```text
┌──────────── Discard unsaved profile changes? ────────────────┐
│ Your unsaved profile changes will be lost.                   │
│                         [Keep Editing] [Discard Changes]     │
└──────────────────────────────────────────────────────────────┘
```

- Triggered by Cancel, Escape, or editor close while dirty.
- **Keep Editing** is cancel role and preserves all fields.
- **Discard Changes** invalidates a pending load and dismisses without mutation.
- Save in progress blocks the sheet's close controls.
- Closing/quitting the main window uses the equivalent AppKit warning: conversation
  messages and drafts are kept. Dirty state is not cleared until closure really occurs,
  because a later storage/quit guard may keep the app alive.

**Evidence:** `ProfileEditorView.swift:257-277,420-455`;
`NativeShellApp.swift:1386-1400,1441-1450`. Tests:
`ProfileEditorTests.swift:50-67,131-147`; `ProfileWorkspaceTests.swift:197-267`.

---

## M07 — Profile reload / edit conflict state

**Status:** Implemented inline error plus destructive reload confirmation.

```text
┌────────────────────────── Edit Bot ──────────────────────────┐
│ …current unsaved fields…                                     │
│ ⚠ This profile changed. Review the latest values…           │
│ [Reload latest]                                              │
└──────────────────────────────────────────────────────────────┘

            ↓ when dirty

┌──────────────── Reload the latest profile? ─────────────────┐
│ Reloading discards the edits in this form.                   │
│                              [Keep Editing] [Reload]         │
└──────────────────────────────────────────────────────────────┘
```

- A stale compare-and-swap save fails without overwriting the latest record.
- **Reload latest** reloads immediately when clean; when dirty it opens the second
  confirmation above.
- Load requests carry a generation. A late older response cannot replace a newer load.
- Failed load/save never silently closes the sheet or mutates the current form.

**Evidence:** `ProfileEditorView.swift:124-163,207-254,393-455`;
`EditingWorkspace.swift:83-100`. Tests: `ProfileEditorTests.swift:68-129` and
`ProfileWorkspaceTests.swift:130-150`.

---

## M08 — Confirmed bot deletion

**Status:** Implemented only for durable workspaces. Offline repository, coordinator,
native-controller, and rendered smoke evidence exist. Destructive physical UI clicking,
disk-full/power-loss, and live-provider cancellation are unverified.

### Entry and exit

- Enter from a direct conversation context menu → **Delete Bot…**.
- Availability requires a persistent repository/coordinator and no conflicting save,
  send, attachment, export, profile, routine, or deletion operation.
- Pending drafts are flushed before the impact plan is calculated.
- Cancel or Escape closes only before deletion is accepted.
- **Delete Bot** has no Return/default shortcut.

```text
┌──────────────────── Permanently delete bot? ─────────────────┐
│ Bot Alpha                                                     │
│ Delete 1 direct conversation, 42 messages, 1 draft, …        │
│ Delete 2 stored text attachments (918 bytes)…                 │
│ Stop 1 active or queued reply…                                │
│ Stop 1 active routine run…                                    │
│ Remove from 2 groups:                                         │
│ • Project crew — 2 members remain                             │
│ • Pair — 1 member remains; repair before sending              │
│                                                               │
│ Providers and stored credentials are kept. Cannot be undone.  │
│ [Cancel]                                          [Delete Bot]│
└───────────────────────────────────────────────────────────────┘
```

### Impact contract

The current plan names and counts:

- direct conversations, all their messages and drafts;
- generation records plus active/queued affected replies;
- routines owned by the bot, complete run history, and active routine runs;
- exact unshared stored attachment count and raw bytes;
- every affected group, title, ordered remaining member IDs, and repair warning.

Deletion removes the bot, its direct conversations/history/drafts/generation records,
owned routines/run history, and attachment payloads with no surviving reference.
It retains group conversations, group history/drafts/generations, immutable historical
speaker names, shared attachments, providers, and credentials.

### State and failure behavior

| State | UI/behavior |
|---|---|
| Planning | **Checking affected records…**; destructive action disabled. |
| Ready | Exact captured impact shown; **Delete Bot** enabled. |
| Accepted | Spinner; Cancel disabled; quit/reconnect joins operation. |
| Impact changed / failure | Plan cleared, sanitized error shown, **Review Current Impact** required before another delete attempt. Affected replies may already be stopped. |
| Commit succeeded, refresh failed | Reports deletion succeeded but workspace needs reopen; never offers a destructive retry. |
| Success | Sheet closes; selected deleted conversation falls back safely; notice says group history/shared providers were kept. |

The core rechecks impact before cancellation and again in the repository transaction.
Forged caller cancellation scope does not widen the deletion. A failed database save
rolls back stored deletion effects, though remote/provider cancellation cannot be undone.

### Accessibility

- IDs: `bot-delete-sheet`, `bot-delete-confirm`, `bot-delete-reload`.
- Bot name is selectable; impact is normal readable text.
- VoiceOver focus restoration and physical context-menu activation remain manual gaps.

**Evidence:** `BotDeletionView.swift:9-83`;
`BotDeletionWorkspace.swift:8-184`; `BotDeletion.swift:3-103`.
Tests: `BotDeletionWorkspaceTests.swift:8-318`,
`BotDeletionTests.swift:58-277`, and `BotDeletionCoordinatorTests.swift:39-304`.

---

## M09 — Group needs repair

**Status:** Implemented inline composer block state after deletion leaves fewer than two
available members.

```text
┌──────────────────── current group conversation ──────────────┐
│ …history remains readable…                                   │
├──────────────────────────────────────────────────────────────┤
│ Group needs repair                                            │
│ History and drafts are kept. Choose at least two available…  │
│ [Edit Group…]                                                 │
│ [composer/send disabled by validation boundary]               │
└───────────────────────────────────────────────────────────────┘
```

- The group and its transcript remain readable with zero or one valid member.
- **Edit Group…** enters M05.
- New sends and retries reject before credential reads or network transport.
- Repair requires 2–6 distinct available members; history/draft remains unchanged.

**Evidence:** `WorkspaceView.swift:515-526`;
`BotDeletionWorkspace.swift:18-33`; `EditingWorkspace.swift:115-134`.
Tests: `BotDeletionWorkspaceTests.swift:138-187,246-262` and
`BotDeletionCoordinatorTests.swift:273-304`.

---

## M10 — Settings window shell

**Status:** Implemented as one separate scrollable native window in durable mode.
It is not a tabbed settings UI. Sample mode uses the reduced `PrototypePanel.settings`
surface and does not expose the full provider/export contract.

### Entry and exit

- Enter from app menu **Settings…** (`⌘,`) or inspector gear.
- **File → Export Workspace…** opens Settings if necessary, then immediately enters
  the M18 export chooser.
- Reopening while present brings the single existing Settings window forward.
- Window is resizable, default `580×740`, minimum `520×620`, and inherits effective app
  appearance.
- Closing while provider or appearance edits are dirty presents the AppKit alert below.
  Closing is blocked during provider save.

```text
┌──────────────────── Bot Workspace Settings ──────────────────┐
│ Model Provider                                                │
│ Add an OpenAI-compatible endpoint or explicitly imported…    │
│                                                               │
│ Workspace export                                      M17     │
│ Appearance and layout                                 M16     │
│ [ ] Show hidden conversations in this session                 │
│ Configuration                                         M12/14  │
│ Setup template (new only)                             M11     │
│ Connection / disclosure / credential protection              │
│                                                               │
│                                           [Save … and use]     │
└───────────────────────────────────────────────────────────────┘
```

Dirty close alert:

```text
┌────────────── Discard unsaved Settings changes? ──────────────┐
│ Unsaved appearance and provider edits, including any entered │
│ credential, will be discarded.                               │
│                         [Keep Editing] [Discard Changes]      │
└───────────────────────────────────────────────────────────────┘
```

### Cross-section state

- **Show hidden conversations in this session** applies immediately to the current
  session, independently of the saved appearance edit buffer.
- Provider and appearance dirty flags jointly guard window close/quit.
- Closing resets model discovery and clears entered API/Codex credentials from form
  state.
- Saving one section does not implicitly save the other.

**Evidence:** `ProviderSettingsView.swift:89-163`;
`NativeShellApp.swift:1297-1309,1346-1379,1401-1429`.
Rendered Settings fixture selection is visible in `NativeShellApp.swift:1474-1516`;
this is offline screenshot/smoke infrastructure, not physical UI automation.

---

## M11 — Provider setup template and replacement confirmation

**Status:** Implemented for **New configuration** only. Templates prefill editable
metadata; they do not connect or import credentials.

```text
Setup template: [ Choose a template (optional) ▾ ]
                • Custom compatible endpoint
                • OpenAI Platform
                • Z.ai general API
                • 9router local gateway

when current form is dirty:
┌──────── Replace this form with a setup template? ────────────┐
│ Name, endpoint, model and HTTP choice will be replaced.      │
│ Any entered credential is cleared; no connection is made.   │
│                         [Keep Editing] [Replace Form]        │
└──────────────────────────────────────────────────────────────┘
```

### Template behavior

| Template | Prefill behavior |
|---|---|
| Custom compatible endpoint | Example HTTPS compatible root; blank name/model. |
| OpenAI Platform | Platform root; blank model; explicitly requires Platform API key/billing rather than ChatGPT login. |
| Z.ai general API | General API root; suggested editable model; does not claim account access or Coding Plan quota. |
| 9router local gateway | Loopback root; blank exact model; still requires explicit loopback-HTTP opt-in and router key. |

Applying any template:

- sets provider type to OpenAI-compatible API;
- replaces name/root/model;
- clears API-key and imported Codex credential form state;
- resets/cancels model discovery;
- turns loopback HTTP permission off, including for the local template;
- performs no network request.

**Evidence:** `ProviderSettingsView.swift:178-208,616-628`;
`ProviderPreset.swift:3-36`. Provider template behavior is covered by core preset and
provider validation suites; the alert itself has no dedicated XCUITest.

---

## M12 — OpenAI-compatible provider configuration

**Status:** Implemented metadata + credential workflow. Transport is text-only compatible
chat/SSE. Offline tests cover credential/persistence boundaries. Real providers,
account entitlements, billing, and production signing/Keychain are live unverified.

### Configuration selection and dirty switching

- Picker lists **New configuration** plus saved provider names.
- Existing selected configuration is preferred on initial open; otherwise the first
  saved provider is loaded.
- Switching configuration while dirty asks **Discard unsaved provider changes?**.
  **Discard Changes** clears edits and any entered credential, then loads the requested
  configuration. **Keep Editing** retains the current form.

```text
Configuration: [ New configuration / Saved provider ▾ ]
Setup template: [ optional, new only ▾ ]

┌──────────────────────── Connection ──────────────────────────┐
│ Provider type: [ OpenAI-compatible API ▾ ]                   │
│ Name:          [ Work account___________________________ ]   │
│ API base URL:  [ https://provider.example/v1___________ ]   │
│ Model:         [ exact-model-id_________________________ ]   │
│ [Discover local models]                              M13     │
│ Credential storage: [Protected Keychain / This session only]│
│ Credential:    [••••••••••••••••••••••••••••••••••••• ]   │
│ [ ] Allow HTTP for loopback development servers             │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────── What is sent ────────────────────────┐
│ Destination host + model                                     │
│ Up to 100 prior messages, current draft, bot description     │
│ Attachments are not sent  ← currently rendered, but stale    │
└──────────────────────────────────────────────────────────────┘
Credential protection: …                                       │
                                      [Save and use]            │
```

> **Known UI contradiction:** Settings currently renders **Attachments are not sent**
> (`ProviderSettingsView.swift:475-480`). That sentence predates the implemented
> confirmed text-attachment workflow. Stored text attachments can be transmitted only
> after the separate per-send review described in `docs/ATTACHMENTS.md`; images and
> unsupported binary files cannot. Treat the Settings sentence as a UI defect to fix,
> not as the current transport contract. Routine authorization remains text-only and
> correctly blocks attachment-bearing context.

### Exact fields and validation

| Field | Contract |
|---|---|
| Provider type | OpenAI-compatible API or Codex login. Changing kind clears entered credentials/discovery and requires fresh kind-matching credential. |
| Name | Trimmed 1–80 characters. |
| API base URL | Valid compatible HTTPS root. HTTP is accepted only for explicit loopback development configuration. |
| Model | Non-empty exact provider identifier; saved trimmed. |
| Credential storage | **Protected Keychain** (default) or **This session only**. |
| Credential | Required for new config, destination change, storage-mode change, or provider-kind change. Max 16,384 UTF-8 bytes; nonblank; no newline/NUL. |
| Loopback HTTP | Explicit checkbox; never relaxes HTTPS for remote providers. |

For an existing provider, the secure field is **Replacement credential**. Leaving it
blank retains the current secret only when API root, credential lifetime, and provider
kind remain compatible. The app never reads the saved value back into the form.

### Credential lifetime contract

- **Protected Keychain:** writes to macOS Keychain. A write failure is surfaced and
  never falls back silently to memory.
- **This session only:** retains secret only in the current app process. Provider
  metadata and an opaque reference persist, but relaunch requires re-entry.
- Switching storage modes requires a replacement key; secrets are not copied.
- Metadata save failure removes the new unused replacement where possible and preserves
  the old saved configuration/credential.

### Save and network behavior

- **Save and use** / **Save changes and use** is default action and selects the saved
  provider for new replies.
- Saving validates and persists configuration/credential; it does **not** send chat,
  call a models endpoint, or verify account access.
- Destination disclosure derives a host from the entered URL; it must not show private
  credentials.
- Generic provider errors are sanitized before display.

### Accessibility

IDs: `provider-configuration-picker`, `provider-kind`, `provider-name`,
`provider-api-root`, `provider-model-id`, `provider-credential-storage`,
`provider-secret`, `provider-loopback-http`, `provider-destination-disclosure`,
`provider-context-disclosure`, `provider-settings-error`, `provider-save`.

**Evidence:** `ProviderSettingsView.swift:48-78,210-343,470-549,551-675`;
`ProviderWorkspace.swift:4-21,277-389`; `SessionAwareCredentialStore.swift:3-63`.
Tests: `ProviderWorkspaceTests.swift:9-210,669-720` and
`CodexProviderSettingsTests.swift:216-325`.

---

## M13 — Local model discovery

**Status:** Implemented only for validated local 9router-style model catalogs. URLProtocol
and synthetic catalog tests are offline verified. A real router/account chat is live
unverified.

```text
[Discover local models]  (spinner) [Cancel]
Local 9router only. Sends GET /models with no key or chat content.

[ Filter discovered model IDs______________________________ ]
[ Choose discovered model ▾ ]
23 of 120 IDs match; menu shows at most 80…
```

### Entry, actions, and states

- Available only for OpenAI-compatible type when the root passes the local-endpoint
  policy and loopback HTTP is explicitly allowed where needed.
- **Discover local models** becomes **Refresh local models** after a successful load.
- Loading shows a progress indicator and **Cancel**.
- Filtering is case-insensitive; menu displays at most 80 matching IDs.
- Choosing a result writes its exact identifier into Model. Discovery never replaces
  typed model text automatically.
- Empty success says the router advertised no models; manual entry remains possible.
- Errors are sanitized and do not echo raw server body/root secrets.

### Network and privacy contract

- Explicit click sends credential-free `GET /models` only.
- It sends no saved key, cookies, chat content, draft, or bot description.
- Remote/nonapproved HTTP roots do not start a catalog task.
- Changing root, loopback permission, template, configuration, provider type, or closing
  Settings cancels/invalidates the prior lookup. Late results cannot overwrite newer form state.
- A model list proves neither key validity nor upstream/account/model access.

**Evidence:** `ProviderSettingsView.swift:401-468`;
`ModelDiscoveryController.swift:5-58`; `LocalRouterModelCatalog.swift:7-170` (endpoint
and response limits). Tests: `ModelDiscoveryTests.swift:8-96` and
`ModelCatalogTests.swift:8-246`.

---

## M14 — Codex login provider configuration

**Status:** Implemented experimental, text-only, fixed-destination adapter. Offline auth
fixtures and provider state-machine tests exist. Real account/model availability and
long-term private API compatibility are live unverified and not guaranteed.

```text
┌──────────────────────── Connection ──────────────────────────┐
│ Provider type: [ Codex login (experimental) ▾ ]              │
│ Name:          [ Personal Codex_________________________ ]   │
│ Fixed destination: [fixed adapter origin, read-only]         │
│ Model:         [ exact account-supported model__________ ]   │
│ [Import Codex auth.json…]                     M15            │
│ ✓ Imported for this session                                   │
└──────────────────────────────────────────────────────────────┘
┌──────────────────────── What is sent ────────────────────────┐
│ Text-only reply request to the fixed origin using the model  │
│ Tools disabled; no fallback endpoint                          │
└──────────────────────────────────────────────────────────────┘
Credential protection: process memory only; re-import on quit. │
                                      [Save and use]            │
```

### Differences from API-key provider

- Fixed, noneditable destination; loopback HTTP is forbidden.
- No API-key secure field and no storage picker.
- Credential comes only from explicit M15 file import.
- Imported access token and optional account ID live in process memory only.
- Provider metadata persists, but the login never persists to workspace or Keychain.
- Relaunch, expiration, or rejection requires explicit re-import.
- The app never refreshes or logs out the Codex account and never falls back to another endpoint.

### Save rules and drift

- New configuration or a change from API-key type requires a fresh imported credential.
- API and Codex credentials cannot be supplied to the wrong type or together.
- Fixed-root or HTTP mutation is rejected before credential persistence.
- The suggested initial model is only a convenience and is not discovery or an
  availability promise.
- Saving is not a connection test. A missing session login keeps a later draft and
  starts no transport.

### Accessibility

IDs: `provider-codex-fixed-root`, `provider-import-codex-login`,
`provider-codex-imported-status`, plus shared M12 name/model/save/disclosure IDs.

**Evidence:** `ProviderSettingsView.swift:257-261,308-399,493-510,539-548`;
`ProviderWorkspace.swift:303-367`; `CodexResponsesProvider.swift:1-127`.
Tests: `CodexProviderSettingsTests.swift:39-325` and `CodexProviderTests.swift:8-211`.

---

## M15 — Import Codex auth.json

**Status:** OS-owned `NSOpenPanel` plus implemented bounded importer. Offline file tests
verify parsing/redaction. The repository does not automate the physical macOS picker.

```text
macOS Open Panel (layout owned by macOS)
┌──────────── Import Codex login for this session ─────────────┐
│ Choose the auth.json maintained by Codex. BotWorkspace       │
│ reads it once and does not modify or copy it.                │
│                                                               │
│ [filesystem browser / filename field — OS-owned]              │
│                                          [Cancel] [Import]     │
└───────────────────────────────────────────────────────────────┘
```

### Selection and parsing contract

- JSON files only, one file, no directories; aliases resolve.
- User explicitly selects the file; there is no home-directory scan or startup import.
- Security-scoped access is balanced.
- File must be regular and at most 1 MiB; read is bounded to limit + 1 byte and occurs once.
- Parser accepts the required ChatGPT-mode envelope and retains only access token plus
  optional account ID in a redacted session envelope.
- Raw file, path, refresh token, ID token, account details, and original JSON are not
  copied, modified, displayed, or persisted.

### Cancel/failure behavior

- Cancel returns to M14 unchanged and starts no save/network request.
- While the panel is active, Settings shows a small waiting indicator and disables
  another import.
- Invalid/oversized/unreadable data clears the candidate imported credential and shows
  a sanitized provider error.
- If the form switches kind or starts another import, a late result is ignored by its
  generation guard.

**Evidence:** `CodexAuthFileImporter.swift:6-52`;
`ProviderSettingsView.swift:345-399,635-640`; `CodexSessionCredential.swift:3-64`.
Tests: `CodexProviderSettingsTests.swift:9-37`. **Gap:** no XCUITest of Open Panel
keyboard navigation, sandbox prompt, or VoiceOver wording.

---

## M16 — Appearance and layout settings

**Status:** Implemented detached edit buffer in durable Settings. Preference storage and
semantic light/dark palettes are offline verified. Physical Follow-System transitions,
IME variation, VoiceOver, and every supported macOS release remain manual gates.

```text
┌────────────────── Appearance and layout ─────────────────────┐
│ Appearance: [Dark / Light / Follow System ▾]                 │
│ [x] Show sidebar                                             │
│ [x] Show conversation details when space permits             │
│ Saved on this Mac; divider widths persist separately…        │
│ [Cancel Changes]                         [Save Appearance]    │
└──────────────────────────────────────────────────────────────┘
```

### Fields and actions

| Element | Contract |
|---|---|
| Appearance | **Dark**, **Light**, or **Follow System**. Default is Dark. |
| Show sidebar | Saved workspace-window preference. |
| Show conversation details when space permits | Preference, not a promise the inspector fits at narrow widths. |
| Cancel Changes | Restores draft from current saved preferences. |
| Save Appearance | Applies only appearance/sidebar/inspector flags and persists them. |

### State and persistence

- Draft is detached: changing controls does not live-apply.
- Save/Cancel enable only when dirty.
- Divider widths are not part of the form draft. Adjustments made while Settings is
  open survive a later appearance save.
- Widths clamp to sidebar `240...400` and inspector `280...440`; invalid stored values
  recover per field.
- Inspector automatically hides when the picker is open or width is insufficient,
  without erasing the user's preference. It returns when space permits.
- Preferences use local `UserDefaults` and are excluded from workspace export.

### Accessibility and input

IDs: `appearance-settings`, `workspace-appearance`, `preference-sidebar`,
`preference-inspector`, `cancel-appearance-settings`, `save-appearance-settings`.
Pane dividers expose **Resize pane**, point values, and adjustable increment/decrement.
AppKit composer identity/text/selection are preserved across tested appearance changes;
marked-text retention itself may follow OS behavior.

**Evidence:** `AppearanceSettingsSection.swift:3-53`;
`WorkspaceLayout.swift:3-40`; `WorkspacePreferences.swift:4-131`;
`WorkspaceView.swift:9-39,117-145`. Tests: `AppearanceWorkspaceTests.swift:8-127`,
`WorkspacePreferencesTests.swift:11-121`, and `ThemeTests.swift:9-109`.

---

## M17 — Workspace export section

**Status:** Implemented in durable Settings; disabled in preview/nonpersistent mode or
during conflicting destructive/file operations. Export is JSON only; import/restore is
not implemented.

```text
Workspace export
Save a JSON snapshot of all saved conversations, prompts, drafts,
exact stored text-attachment bytes, routine history, provider endpoints…
JSON with base64 attachment payloads · No import/restore yet ·
Unsaved profile/provider edits are not included

[Export Workspace…]  (spinner) Exporting…
✓ Exported N conversations, M messages, … Stored credentials excluded.
or
⚠ Export did not complete. Check the destination…
```

### Included

- all bots, including hidden;
- direct/group conversations with member order;
- all messages, attribution, replies, drafts, generations/partial state;
- routines and complete run history;
- allowlisted provider metadata: ID, name, kind, API root, model, loopback flag;
- exact referenced stored attachment metadata and bytes (base64 in JSON).

### Excluded or not scrubbed

- Credential references and values, auth files/tokens, Keychain content, and headers
  are excluded.
- Unsaved profile/provider edits, appearance preferences, and display name are excluded.
- Secrets the user typed into messages, prompts, names, endpoint paths, or attachments
  are ordinary content and are **not** scrubbed. UI warns to review before sharing.
- No import/restore exists; this is not a database backup.

### Availability

`Export Workspace…` requires a persistent, opened repository and no loading, closing,
exporting, bot deletion, attachment import/confirmation, or active deletion sheet.
One export is claimed synchronously.

**Evidence:** `WorkspaceExportSection.swift:3-35`;
`WorkspaceExportFlow.swift:16-41`; `WorkspaceExport.swift:3-21,92-180`.
Tests: `WorkspaceExportFlowTests.swift:29-42,80-106` and
`WorkspaceExportTests.swift:22-180`.

---

## M18 — Export destination / overwrite confirmation

**Status:** OS-owned asynchronous `NSSavePanel`. The app configures semantics, not exact
pixel layout. Synthetic destination tests exist; physical external-folder selection,
sandbox grant, overwrite UI, disk-full, and VoiceOver are unverified.

```text
macOS Save Panel (layout and overwrite dialog owned by macOS)
┌────────────────────── Export Workspace ──────────────────────┐
│ Includes saved conversations, prompts, drafts and provider   │
│ endpoints. Stored credentials are excluded. Review content…  │
│                                                               │
│ Save As: [BotWorkspace-export.json_______________________]    │
│ Where:   [user-selected folder ▾]                             │
│                                           [Cancel] [Save]      │
└───────────────────────────────────────────────────────────────┘
```

### Contract

- Allowed content type is JSON only; default filename is
  `BotWorkspace-export.json`; directories may be created.
- The panel attaches as a sheet when a key window without another sheet is available;
  otherwise it is app-modal.
- macOS owns existing-file overwrite confirmation.
- Cancel means no export-driven draft flush, snapshot, encoding, or write.
- Pending choice is cancelled by quit. Once a destination is accepted and writing has
  begun, close/reconnect waits for completion.
- Only a file URL with `.json` is accepted. Existing destination must be a regular file
  with one hard link; symlinks, hard-linked aliases, directories, and non-file URLs fail.
- Write uses Foundation atomic replacement, not an fsync/crash-durability guarantee.
  A private trusted folder is required; preflight is not a descriptor-based defense
  against malicious concurrent path replacement.

**Evidence:** `WorkspaceExportDestination.swift:5-81`;
`WorkspaceExportFlow.swift:42-78`. Tests:
`WorkspaceExportFlowTests.swift:9-78,198-278` and
`WorkspaceExportFileWriterTests.swift:7-130`.

---

## M19 — Export progress, success, and failure

**Status:** Implemented inline in M17. Offline end-to-end snapshot/encode/temp-file write
is verified; large real workspaces are not benchmarked.

### Flow

```text
M17 Export button
   ↓ claim single flight
M18 destination chooser
   ├─ Cancel → idle, no status/error, no export-driven flush/write
   └─ Accept
       ↓ flush latest drafts
       ↓ capture one repository revision
       ↓ encode deterministic JSON (100 MiB default limit)
       ↓ validate destination + atomic write
       ├─ success → counts shown, credentials-excluded reminder
       └─ failure → sanitized actionable error, no success claim
```

### Status contract

- During the entire chooser/export operation the button is disabled and shows spinner
  plus **Exporting…**.
- Success reports conversation, message, routine-history, attachment count/bytes, and
  **Stored credentials excluded**. It never reports the chosen path.
- Known size errors retain their exact safe count/limit wording. Arbitrary filesystem
  errors become the generic destination/space/save-status message and do not leak paths.
- Workspace change before write invalidates the export. A late callback cannot write the
  old snapshot into a newly connected workspace's state.
- Draft flush failure writes nothing, keeps the draft dirty for retry, and reports no success.
- Format version/source schema are currently 3. Default final encoded-size limit is
  100 MiB and fails without truncation.

**Evidence:** `WorkspaceExportFlow.swift:4-97`;
`WorkspaceExportSection.swift:19-33`; `WorkspaceExport.swift:72-97`.
Tests: `WorkspaceExportFlowTests.swift:9-278` and
`WorkspaceExportFileWriterTests.swift:7-130`.

---

## M20 — Routine management family

**Status:** Implemented only in persistent workspaces. Scheduling and provider activity
run only while the app is open and the Mac is awake. Offline scheduler/provider fixtures
cover the execution state machine. Physical sleep/wake, live provider billing/account
behavior, VoiceOver, and full keyboard traversal remain unverified.

### M20 entry map

- Enter the routine list from the inspector **Routines** section.
- Inspector **+** or header **Routines → Add Routine…** opens M20A.
- Selecting a routine in either list opens M20B.
- A direct chat preselects its bot as the new owner. A group requires an explicit member
  owner. Output always belongs to that owner's direct chat, never the group.

```text
Inspector
┌──────────────────────── Routines ────────────────────────────┐
│ Routines                                                 (+) │
│ ◷ Daily review                                               │
│   Daily 09:00 · Asia/Bangkok                                 │
│   Owner: Alpha · direct chat       (shown for group context) │
│   Enabled · while app is awake                                │
│   Next: Sep 11, 9:00 AM                                       │
│                                                               │
│ No runs while app is closed, Mac asleep, or logged out.      │
└───────────────────────────────────────────────────────────────┘
```

**Evidence:** `RoutineViews.swift:4-65`; `RoutineWorkspace.swift:21-56`.

### M20A — New/Edit Routine

```text
┌──────────────────────── New Routine ─────────────────────────┐
│                                                       (×)    │
│ Name      [ Daily review_______________________________ ]    │
│ Prompt    [____________________________________________ ]    │
│           [____________________________________________ ]    │
│                                             120 / 32,000     │
│ Owner     [ Alpha ▾ ]       (locked for existing routine)    │
│ Schedule  [ Interval | Daily ]                                │
│ Interval: [60] minutes [stepper]    OR Hour [09] Minute [00] │
│ Time zone [ Asia/Bangkok ▾ ]                                 │
│ Provider  [ Work — model-id ▾ ]                              │
│ [ ] Enable automatic runs                                    │
│ ┌──────── Paused destination approval / Auto disclosure ──┐ │
│ │ prompt + up to 100 recent owner-chat messages → root/model│ │
│ └───────────────────────────────────────────────────────────┘ │
│ [ ] I approve/authorize this prompt and destination binding  │
│ ⚠ validation/save error                     [Reload latest] │
├──────────────────────────────────────────────────────────────┤
│                               [Cancel] [Save]                │
└──────────────────────────────────────────────────────────────┘
```

#### Fields and validation

| Field | Contract |
|---|---|
| Name | Trimmed 1–80 characters. |
| Prompt | Nonempty after trimming; original prompt length at most 32,000 characters. |
| Owner | New routine: visible member explicitly chosen (direct chat may preselect). Existing routine: immutable and picker disabled. |
| Interval | 5–525,600 minutes. Interval uses elapsed time across DST. |
| Daily | Hour 0–23 and minute 0–59 in selected named IANA timezone. |
| Time zone | `UTC` or a known named IANA zone; no silent local/fixed-offset substitution. |
| Provider | Optional only while paused. Lists saved providers sorted by name with model. |
| Enable automatic runs | Requires provider and current disclosure authorization. |

#### Consent and detached-state contract

- New form defaults: interval 60 minutes, current named timezone, paused, no provider.
- Saving a paused routine with no provider sends nothing and needs no authorization.
- A paused routine with a new/changed prompt, owner, or provider binding requires
  **I approve this prompt and destination binding**. This consent still sends nothing.
- Enabled save always requires **I authorize these automatic transmissions**.
- Disclosure states: exact prompt, up to 100 recent messages from owner's direct chat,
  destination, model, possible charges, and awake/open-only limit.
- Any relevant form change clears consent. Provider metadata drift also clears consent,
  even if the selected provider ID is unchanged.
- A changed provider binding during/after accepted save keeps the form open for review.

#### Dirty, save, and conflict states

- Loading existing routine shows **Loading routine…**.
- Invalid form shows inline warning and disables Save.
- Cancel/Escape/close while dirty opens **Discard unsaved routine changes?**.
- Reload on dirty error asks **Reload the latest routine?** and clearly says edits are discarded.
- Accepted save is synchronously owned; quit waits. Newer edits made during save remain
  dirty with **Saved. Newer edits remain in this form.**
- Existing stale routine/profile/binding conflicts do not overwrite newer state.

#### Keyboard and accessibility

- Name focuses after load. Cancel/Escape share dirty-aware behavior; Save is default.
- IDs: `routine-close`, `routine-name`, `routine-prompt`, `routine-owner`,
  `routine-trigger`, `routine-interval-minutes`, `routine-interval-stepper`,
  `routine-daily-time`, `routine-timezone`, `routine-provider`, `routine-enabled`,
  `routine-transmission-disclosure`, `routine-authorize-transmission`,
  `routine-validation-error`, `routine-save-error`, `routine-reload-latest`,
  `routine-cancel`, `routine-save`.

**Evidence:** `RoutineEditorView.swift:37-187,189-353,355-483,554-781`;
`RoutineWorkspace.swift:38-112`. Tests: `RoutineEditorTests.swift:23-299` and
`RoutineWorkspaceTests.swift:56-69,209-284`.

### M20B — Routine detail, controls, status, and history

```text
┌──────────────────── Daily review ───────────────────── [Done]┐
│ Owner: Alpha. Output goes to this bot's direct chat.         │
│ Daily 09:00 · Asia/Bangkok                                   │
│ <selectable prompt>                                          │
│ Sends prompt + up to 100 messages → provider/model…          │
│ Next planned: …   OR   Paused — no scheduled runs.           │
│ [Edit] [Run Now] [Pause | Resume…]                 [Delete…] │
│ ⚠ routine error                                              │
│ ──────────────────────────────────────────────────────────── │
│ Run history                                      [Refresh]   │
│ Latest 100 records plus any active run.                       │
│ ┌ Completed | Manual                         timestamp      ┐ │
│ │ destination host · model                                  │ │
│ │ [Open owner's chat]                                       │ │
│ └───────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

#### Controls

- **Edit:** opens M20A nested over detail.
- **Run Now:** opens M20C. Disabled while another routine action exists or any displayed
  run is nonterminal.
- **Pause:** prevents new scheduled runs and clears next-run time; it does not stop an
  already active run.
- **Resume…:** opens M20A so destination/automatic consent is reviewed; it does not
  silently toggle on.
- **Delete…:** asynchronously computes exact routine/run impact, then opens M20D.
- **Done/Escape:** closes detail only when nested editor is absent.

#### History/status

- Shows latest 100 records plus any active run that fell outside the chronological page
  (for example after clock rollback), so Stop remains reachable.
- Status labels are the persisted typed status, plus Manual/Scheduled/Scheduled summary.
- Nonterminal run exposes **Stop**; Stop preserves partial text and rejects late deltas.
- Shows created timestamp, typed human-readable failure, skipped occurrence range,
  credential-free provider host/model binding, and **Open owner's chat** when available.
- Detail refreshes roughly once per second while open; failure stops the loop and shows
  sanitized routine error.

Failure labels explicitly distinguish missing/changed provider, missing/invalid
credential, login required, unavailable/rate limited/invalid response, attachments not
supported, output/storage/schedule failure, cancelled/interrupted, and superseded
occurrences. There is no automatic network retry.

**Evidence:** `RoutineViews.swift:67-195,229-282`;
`RoutineWorkspace.swift:49-77,124-150,169-210,243-288`.
Tests: `RoutineWorkspaceTests.swift:70-207,230-331` and
`RoutineExecutionTests.swift:66-470`.

### M20C — Run Now consent

```text
┌──────────────────── Run this routine now? ───────────────────┐
│ Sends this prompt and up to 100 recent messages from Alpha's │
│ direct chat to <destination>, model <model>. Charges may…    │
│ This is one new run, even while paused. Calendar unchanged.  │
│                                      [Cancel] [Run Now]       │
└──────────────────────────────────────────────────────────────┘
```

- One-time explicit authorization for the captured routine definition.
- Works while paused and does not move/enable the calendar schedule.
- Scheduler rechecks definition/provider binding after credential I/O; drift blocks
  transmission rather than borrowing current composer selection.
- Output and run history go to owner's direct chat. Existing equal-text draft and group
  draft remain.
- Missing/changed binding creates visible blocked history; no fake success.

**Evidence:** `RoutineViews.swift:196-213,252-259`;
`RoutineWorkspace.swift:114-122`. Tests: `RoutineWorkspaceTests.swift:70-123` and
`RoutineExecutionTests.swift:66-165,199-236`.

### M20D — Delete routine confirmation

```text
┌────────────── Delete routine and its history? ───────────────┐
│ Delete “Daily review” and all 12 history records.             │
│ 1 active run will be stopped. Chat messages/drafts are kept. │
│ Future scheduling is paused first; failed deletion remains…  │
│                              [Cancel] [Stop and Delete]       │
└──────────────────────────────────────────────────────────────┘
```

- Exact confirmation contains routine name, run-history count, and active-run count.
- Destructive label is **Delete** with no active runs, otherwise **Stop and Delete**.
- Accepted deletion first atomically pauses future scheduling against the confirmed
  history set, stops active runs, then deletes definition/history.
- Chat messages and drafts remain.
- If deletion fails after pause, routine remains paused for explicit review.
- New history between plan and delete invalidates the operation rather than widening
  consent silently.

**Evidence:** `RoutineViews.swift:214-228`;
`RoutineWorkspace.swift:139-167`. Tests: `RoutineWorkspaceTests.swift:152-193` and
`RoutineRepositoryTests.swift:49-80,164-192`.

### Routine execution boundary

```text
App launch / Mac wake
        ↓ reconcile due schedules
enabled routine + bound provider + available credential
        ↓ atomically claim one occurrence/run
        ↓ send prompt + ≤100 owner-direct-chat messages
        ↓ stream attributed reply into owner's direct chat
        ↓ terminal run history + next occurrence

App closed / Mac asleep / logged out
        └─ no runs; on return, missed intervals coalesce instead of burst replay
```

- No daemon/remote worker is supplied. The app makes no 24/7 execution claim.
- Wake reconciliation chooses at most the latest due occurrence and records skipped
  ranges instead of catch-up bursts.
- Restart marks unfinished claims interrupted and never silently resubmits them.
- Routine and interactive chat share the provider coordinator's concurrency cap.
- Provider credentials are resolved at execution time but never added to routine records
  or export.

**Evidence:** `RoutineWorkspace.swift:213-241`; `RoutineHost.swift:1-68`;
`RoutineSchedule.swift:1-191`; tests in `RoutineScheduleTests.swift:11-215`,
`RoutineExecutionTests.swift:66-470`, and `RoutineWorkspaceTests.swift:124-150,312-331`.

---

## Cross-screen close and operation ownership

```text
User closes window / quits
          ↓
pending export chooser? ── cancel chooser
accepted export write? ─── wait; failure keeps app open
accepted bot delete? ───── wait; failure keeps app open
accepted routine save? ─── wait, then recheck newer dirty edits
dirty routine form? ────── confirm discard
accepted profile save? ─── wait, then recheck newer dirty edits
dirty profile form? ────── confirm discard
provider save? ─────────── wait/block close
dirty Settings? ────────── confirm discard
draft/storage flush? ───── attempt; failure keeps recovery visible
```

Authoritative implementation: `NativeShellApp.swift:153-205,1386-1450`,
`ProviderWorkspace.swift:392-430`, plus operation-specific workspaces cited above.

## Persistence and network matrix

| Screen | Workspace write | Preference write | Credential access | Network | Explicit consent |
|---|---:|---:|---:|---:|---|
| M01 | Selection may flush drafts | No | No | No | No |
| M02 | Create group | No | No | No | Create action |
| M03 | Create bot + direct chat | No | No | No | Create action |
| M04/M05 | CAS profile/group update | No | No | No | Save; dirty discard separate |
| M08 | Transactional destructive delete | No | Does not read/delete shared provider credentials | May cancel already-started affected transport; no new request | Exact impact + explicit Delete Bot |
| M10/M11 | No by template alone | Session show-hidden toggle only | Entered form state cleared on close/switch | No | Dirty discard |
| M12 | Provider metadata | No | Keychain or process-memory write | No connection test | Save and use |
| M13 | No | No | No | Explicit credential-free local `GET /models` | Discover click |
| M14/M15 | Provider metadata on Save | No | User-selected file read once; process memory only | No connection test | File Import, then Save |
| M16 | No | Local preferences | No | No | Save Appearance |
| M17–M19 | Flush drafts; read atomic snapshot | No | Never reads credential store | No | Export click + OS destination/overwrite |
| M20A | Routine definition | No | No on save | No on save | Binding/automatic disclosure checkbox when required |
| M20B/C | Run history/messages/control state | No | Reads bound credential at run time | Run Now or enabled schedule | One-run alert or prior automatic authorization |
| M20D | Pause + delete routine/history | No | No | Stops active run transport | Exact delete alert |

## Keyboard and accessibility matrix

| Surface | Keyboard contract | Accessibility contract | Known gap |
|---|---|---|---|
| M01/M02 | Query focus; Up/Down; Return selects; `⌘Return` creates group; Escape closes | Named result/chip actions and stable query/create IDs | No physical keyboard/VoiceOver automation |
| M03 | Cancel/default Create; Escape via workspace | Named color buttons; stable name/create IDs | No dirty warning; no explicit initial focus |
| M04–M07 | First field focus; Escape/Cancel; Return default Save; alerts are role-labeled | Headers, validation/errors, member actions, stable IDs | Physical VoiceOver focus restoration unverified |
| M08/M09 | Escape/Cancel before accept; destructive action intentionally has no default Return | Stable sheet/delete/reload/repair IDs | Context menu and post-delete focus not physically automated |
| M10–M16 | `⌘,`; default provider Save; native window close; standard picker/text behavior | Stable IDs for all provider, discovery, Codex, and appearance controls | Full tab order, OS panels, VoiceOver manual |
| M17–M19 | Standard native Save Panel keyboard behavior is OS-owned | Stable export button; status/error selectable | OS overwrite/sandbox/VoiceOver not automated |
| M20 | First-field focus; Escape/Cancel; default Save; Done is cancel action | Stable editor/detail/control IDs and named Stop action | Full traversal and physical sleep/wake manual |

## Implemented versus open product boundaries

### Implemented and offline verified

- Durable bot/group creation, edit CAS, dirty discard, conflict reload, and group repair.
- Confirmed bot deletion with exact record counts and safe group/history retention.
- Manual provider configuration, explicit credential lifetimes, replacement-only secret
  entry, credential-free local model discovery, and experimental Codex file import.
- Detached appearance preferences and responsive saved pane layout.
- Versioned JSON export with exact referenced text-attachment bytes and credential exclusion.
- Routine create/edit, destination consent, awake-only schedule, Run Now, Pause/Resume,
  Stop, typed history, and confirmed deletion.

### Implemented but live/unverified

- Real provider compatibility/account/model availability and billing behavior.
- Production-signed Keychain behavior across distribution/update identities.
- Real Codex session compatibility beyond synthetic fixtures.
- Real local-router discovery/chat beyond URLProtocol/offline fixture evidence.
- External Save/Open Panel sandbox grants and overwrite flow.
- Physical sleep/wake, macOS 14 runtime matrix, VoiceOver, full keyboard traversal,
  IME behavior across every appearance transition, disk-full/power-loss, and hostile
  shared-folder races.

### Not implemented

- Workspace import/restore.
- Provider connection-test button or account/model entitlement verification.
- Provider deletion UI.
- Automatic discovery/import of Codex credentials, token refresh, or logout.
- Background/24×7 routine worker while the app is closed or the Mac sleeps.
- Undo for confirmed bot or routine deletion.
- A live computer/desktop management screen; the workspace inspector remains a separate
  disconnected placeholder unless another feature supplies such a service.
- Dirty-discard confirmation in M03 create-bot form.
- Corrected provider Settings disclosure for implemented confirmed text-attachment
  transmission; the current view still says attachments are never sent.

## Verification commands

These commands validate the management implementation without using a live provider or
the user's real workspace:

```sh
scripts/native-app.sh test
scripts/native-app.sh provider-smoke
scripts/native-app.sh deletion-smoke
scripts/native-app.sh routine-smoke
scripts/native-app.sh export-smoke
```

The smoke commands render real native views against isolated fixtures. They do not prove
physical mouse/keyboard interaction, OS-owned panel traversal, live credentials, paid
network calls, or production distribution. See `docs/PROVIDER-SETUP.md`,
`docs/BOT-DELETION.md`, `docs/ROUTINES.md`, `docs/APPEARANCE.md`, and
`docs/WORKSPACE-EXPORT.md` for subsystem-level contracts and their remaining gates.
