# BotWorkspace — complete feature and screen contract atlas

**Audit date:** 2026-09-10. **Source baseline:** `ab2c2f3` (native group mentions).
**Product:** independent, experimental native macOS app; SwiftUI + AppKit + Core Data.
This is the consolidated screen-by-screen public product documentation. It preserves the earlier ASCII/layout work, adds a detailed
screen inventory, and connects every screen to implementation, state, and visual evidence.
It does **not** turn reference screenshots, old plans, or passing fixtures into shipped features.

## Start here

| Document | What it contains |
|---|---|
| [Workspace screen catalog](SCREENS-WORKSPACE.md) | W-series screen IDs; shell/sidebar/search/chat/composer/groups/mentions/replies/attachments/inspector/catalog/profile; ASCII and control contracts |
| [Management screen catalog](SCREENS-MANAGEMENT.md) | M-series screen IDs; creation/editing, Settings, provider configuration, routine workflows, export/deletion, native dialogs; ASCII and failure behavior |
| [Screenshot catalog](SCREENSHOT-CATALOG.md) | Native BotWorkspace synthetic fixture renders, scenario commands, screen mapping, capture limitations, and uncaptured-state register |
| [Reference screen archive](REFERENCE-SCREENS.md) | R-series original-reference observations; neutral ASCII redraws; differences from the implemented app; private-image handling |
| [Computer/terminal contract](COMPUTER-TERMINAL-CONTRACT.md) | Disconnected current app vs proposed terminal/desktop surfaces; permission/verification gates without private deployment information |
| [Machine-readable screenshot manifest](screenshots/manifest.json) | Capture source commit, scenario commands, image dimensions, SHA-256 hashes; no private screenshot inputs |
| [Original native rewrite acceptance contract](NATIVE-REWRITE-CONTRACT.md) | R01–R09 and T01–T18 product/release requirements; proposals must be read with later implementation evidence |

The Markdown files and bundled **synthetic native screenshots** are the portable dump.
Private reference paths and hashes remain in an ignored local-only index. Original reference images
are not copied into `docs/screenshots`, embedded in the app, or published by this task.

## 1. Reading the status labels

- **Implemented:** reachable native source and state/service behavior exist. This is not
  automatically a claim of real-account compatibility, complete accessibility, or release readiness.
- **Fixture verified:** a named automated test/smoke exercises the behavior with isolated data.
  A screenshot proves a rendered state, not that a person clicked through the workflow.
- **Sample only:** available in `NativeShellPrototype.app` using synthetic session-local data;
  never a seeded production workspace or a real provider/computer response.
- **OS-owned:** the app invokes an AppKit panel/alert; a hosted-view image does not prove
  that panel's real sandbox grant, keyboard behavior, or accessibility.
- **Reference observed:** visible in supplied images, not necessarily implemented here.
- **Proposed / not integrated:** describes a future contract or external service; not
  an app capability and not permission to deploy/control a machine.
- **Unverified / gap:** the relevant test or screenshot was not produced. Preserve the
  gap explicitly instead of borrowing proof from another screen or historical milestone.

**Evidence precedence:** current source and fresh scoped results → feature-specific
contracts → older architecture/prototype notes → reference observations. The original
rewrite document mixes normative requirements, proposed ownership, and checkpoints;
its proposed `App/...xcodeproj` layout is not the current SwiftPM source tree.
A `.app` named `BotWorkspace` does not make its screenshot a production-account capture:
our durable smoke app uses an isolated temporary repository and offline fixtures.

## 2. Information architecture and navigation

```text
Native workspace window
├── Sidebar
│   ├── Search / activity / unread count / hidden conversations
│   ├── Existing direct or group conversation
│   ├── New chat → existing Bot / Create Bot / Create group
│   ├── Marketplace → local templates (not a remote store)
│   └── Local profile menu → profile / Settings / hidden chats
├── Conversation pane
│   ├── Header / bot or group profile / export action
│   ├── Paginated transcript / reply reference / message actions
│   ├── Provider + explicit recipients / mentions / round status
│   └── Reply draft / file chips / native composer / Send or Stop
└── Optional inspector
    ├── Profile summary/edit
    ├── Computer: explicitly disconnected
    └── Routines → edit / run / pause / history / delete

Separate native Settings window
├── Appearance and pane preferences (detached Save/Cancel)
├── Provider configuration and credential handling
├── Experimental Codex login import (separate provider kind)
└── Workspace JSON export
```

```text
DESKTOP — content request 1280 × 880 pt (system titlebar is additional)
+---------------------+----------------------------------+----------------------+
| native controls  +  | Avatar · Conversation      [...] | settings / collapse  |
| Search              |----------------------------------|----------------------|
| selected row        | transcript, reply references     | profile summary      |
| other bot/group     | events and generation status     | computer disconnected|
| unread badges       |                                  | routines             |
|                     |                                  |                      |
|                     | provider + ordered recipients    |                      |
| Marketplace         | reply/file chips                 |                      |
| Local profile       | [+] native text editor   [Send]  |                      |
+---------------------+----------------------------------+----------------------+

MINIMUM — content request 760 × 600 pt
+--------------------+----------------------------------------------+
| Sidebar (clamped)  | Conversation, transcript, status              |
|                    |                                              |
|                    | provider / recipient controls                |
|                    | reply + attachment area / composer           |
+--------------------+----------------------------------------------+
Inspector auto-collapses; preferred visibility is retained for later widening.
```

### Layout, appearance, and interaction constants

| Concern | Current contract / source |
|---|---|
| Minimum window content | 760×600 pt; fresh minimum smokes use `--minimum` |
| Desktop fixture content | 1280×880 pt; small preview 800×650 pt is NOT the minimum gate |
| Sidebar | default 280 pt, saved range 240–400; temporarily constrained when necessary |
| Chat | minimum 424 pt; preserve usable composer before retaining all columns |
| Inspector | default 320 pt, saved range 280–440; auto-collapse does not overwrite preference |
| Palette | Dark default; Light; Follow System; semantic surfaces, native system font |
| Persistence | appearance, two widths and preferred visibility in app-owned UserDefaults; not workspace JSON |
| Window controls | real AppKit titlebar/traffic lights; not painted imitation buttons |
| Text input | AppKit `NSTextView`; native selection, undo, plain-text insertion and marked-text guards |
| Accessibility | named controls and explicit IDs; physical VoiceOver/IME/focus remain independent gates |

See [appearance](APPEARANCE.md), `WorkspaceLayout.swift`, `WorkspacePreferences.swift`,
`Theme.swift`, and `NativeShellApp.swift` under `Prototypes/NativeShell/Sources/NativeShell`.
Screen catalogs specify each reachable shortcut; an original requirement for keyboard
navigation is not evidence that every requested shortcut is currently implemented.

## 3. Feature inventory by user job

| Feature ID | Job / feature | Surface | Status and important boundary |
|---|---|---|---|
| F01 | Open a local workspace | W shell/loading/error | Implemented Core Data load/retry; no cloud account required |
| F02 | Find/switch conversations | W sidebar/search | Implemented; catalog distinguishes actual search scope from broader historical requirements |
| F03 | See latest activity and unread replies | W sidebar/transcript | Persisted counts/previews; only displayed foreground bottom-of-chat acknowledges read |
| F04 | Create a named Bot | M creation; W picker | Stable ID + direct conversation; original avatar geometry; no VM allocation |
| F05 | Edit Bot identity/profile | M profile editor | Detached, identity-bound edits and conflicts; not a provider credential editor |
| F06 | Hide/unhide a Bot | W sidebar/menu | Reversible visibility change, not deletion or routine cancellation |
| F07 | Permanently delete a Bot | M deletion | Reviewed impact plan, destructive confirmation, group repair; no undo promise |
| F08 | Create/edit a group | M picker/editor | 2–6 distinct Bots for valid sendable groups; histories of degraded groups retained |
| F09 | Write and preserve drafts | W composer | Per-conversation text/reply/file identity; flush/restart behavior; no silent discarded draft |
| F10 | Send streamed text | W chat; M provider setup | User-supplied compatible provider, durable transaction before network; no fake AI reply |
| F11 | Stop and retry generation | W status/actions | Partial text retained; attempt binding rejects stale events; no automatic HTTP retry |
| F12 | Choose ordered group recipients | W recipient controls | Explicit order; independent attributed replies, not an autonomous bot conversation |
| F13 | Review multi-recipient sends | W round consent | Frozen shared context, provider/model/file disclosure and request count |
| F14 | Mention group members | W draft/mention menu/consent | Identity-safe binding; malformed/stale/ambiguous mentions block the whole send |
| F15 | Reply to an existing message | W transcript/composer | Conversation-bound reference; persistent draft and jump-to-original handling |
| F16 | Attach text files | W chips; M OS picker | Selected regular UTF-8 files; managed copies; no binary/image/whole-home ingestion |
| F17 | Confirm attached content transmission | W send consent | File identity/content/destination checked before credential/network side effects |
| F18 | Configure compatible providers | M Settings | OpenAI Platform, Z.ai, custom, local 9router templates are suggestions, not account entitlements |
| F19 | Discover local router models | M Settings | Explicit loopback-only, credential-free GET; result is not proof chat will work |
| F20 | Choose credential storage | M Settings | Protected Keychain or explicit session memory; no automatic plaintext fallback |
| F21 | Import experimental Codex login | M Settings/import | Explicit file, memory-only, fixed origin; no refresh owner or generic OAuth login |
| F22 | Change appearance/panes | M Settings, W dividers | Detached Save/Cancel and independent persistent pane adjustments |
| F23 | Create/edit a routine | M routine editor, W inspector | Interval/daily with timezone, owner and provider binding; explicit execution consent |
| F24 | Run/pause/stop a routine | W inspector, M run review | Scheduler only while app runs and Mac is awake; no unattended 24/7 service claim |
| F25 | Inspect/delete routine history | M history/confirmation | Durable typed outcomes and cancellation/deletion boundaries |
| F26 | Export workspace | M export review/save/result | Versioned JSON including hidden data and exact referenced text-file bytes; no import/restore |
| F27 | Use a template | W marketplace/M create | Local synthetic catalog creating independent Bots; not plugin download/subscription |
| F28 | Edit local display profile | W account/profile | Local display metadata; no reference-app account or authentication migration |
| F29 | Inspect a computer | W inspector | Disconnected only; no terminal, desktop video or automation currently embedded |
| F30 | Remote terminal viewer | Future computer contract | Proposed only; no configured service or private deployment information is included |
| F31 | Voice, reactions, teach-a-task | R observed controls | Reference observations or deferred requirements; do not infer functional parity |
| F32 | Distribute to other users/platforms | Build/release gates | Local ad-hoc macOS build; no notarized release, Windows or Linux build claim |

Every W/M catalog entry adds entry/exit points, ASCII, exact actions, empty/error states,
persistence and consent boundaries, and code/test evidence. The screenshot catalog maps
those IDs to renders or explicitly documents why a state has no captured image.

## 4. End-to-end flow contracts

### A. First use and provider setup

```text
Launch → open local store
  ├─ opening → loading state (no sends)
  ├─ failure → actionable storage error / Retry (no destructive reset)
  └─ success → empty or existing workspace
       → create/select Bot → draft
       → no usable provider/credential? retain draft + setup guidance
       → Settings: choose kind/template, destination/model, credential policy
       → explicit Save → select provider in composer → Send
```

The production bundle is not preloaded with private screenshot conversations.
The sample prototype and durable smoke fixtures are separate from normal storage.

### B. Ordinary streaming send

```text
Draft + conversation + provider + target
  → validate/capture context and any required consent
  → acquire permitted credential / reject missing or expired credential
  → atomic user-message + queued-generation commit / matching draft clear
    ├─ save failure → retain draft; ZERO provider dispatch
    └─ success → coordinator queue → connect → stream attributed deltas
                                     ├─ completed
                                     ├─ failed (typed/sanitized error)
                                     ├─ cancelled (partial retained)
                                     └─ interrupted after restart
Retry → explicit new attempt, original user message, preserved previous partial text
```

Up to one active request per conversation and three globally. Context is captured
when queued (up to 100 prior messages), not silently expanded with later replies.
Each delta currently persists individually; write coalescing and performance-budget
success must not be inferred. Visible-text timeouts are 30s first text, 60s idle,
300s total; these are source-configured limits, not timing guarantees for all providers.

### C. Ordered groups and mention targeting

```text
manual ordered recipients OR mentions in current group draft
  → resolve identities (mentions replace, not merge with manual selection)
  → any invalid/stale/ambiguous mention? block ALL send, retain draft
  → capture full round plan: N names/IDs, order, context, files, destination
  → review (all mentions, even 1 recipient; multi-member manual rounds)
  → confirm + re-resolve + compare captured plan BEFORE credentials
  → atomic one user message + N queued attributed generations
  → run member 1 → member 2 → ... → member N
  → Stop round keeps completed output and stops remaining members
```

A later member does not automatically consume an earlier member's answer in the
same round. Typed mentions in assistant output, attachments, previous messages,
or direct-chat text are not instructions. UUID suffixes bind local draft mentions;
valid binding suffixes are removed from the outgoing/stored readable user message.

### D. Files and reply context

```text
Select files → native open panel → bounded regular UTF-8 read
  → atomic managed content + draft identities → removable chips
  → Send → disclose files + provider/model + recipients
  → confirm + stale-plan check → provider text input

Reply on message → draft reply card → cancel OR submit
  → message stores replyToID → later preview resolves original in same conversation
  → loading/unavailable/jump states cannot retarget a newer conversation
```

A file chip is not proof that a provider supports binary attachments. Stored bytes
are exact, but this client only transmits its supported text representation.

### E. Routine lifecycle

```text
Inspector [+] → detached editor → validate name/prompt/schedule/timezone/provider
  → explicit owner + destination consent → save
  → enabled schedule: launch / wake / awake 30-second checks
  → claim occurrence in durable ledger → coordinator → attributed result/history
  → Pause prevents future claims; Stop cancels active work as documented
  → missed occurrences are reconciled without an unbounded catch-up burst
```

Run Now is separately reviewed and does not silently move the recurring schedule.
Daily wall-clock schedules use named timezones and explicit DST policy. Closing/sleep
is not a promise that requests continue remotely; see [routines](ROUTINES.md).

### F. Editing, deletion, and export

```text
Edit → detached buffer tied to stable identity
  ├─ Cancel/dirty close → explicit discard policy
  ├─ concurrent editable-field change → conflict / reload
  └─ valid Save → repository transaction → refreshed UI

Delete Bot → calculate impact → review names/counts/groups → confirm
  → revalidate plan → cancel affected work → transactional deletion/group repair
  → retained degraded group history; repair membership before sending

Export → disclosure → native JSON Save Panel
  ├─ Cancel → no export-driven write
  └─ selected destination → flush drafts → single revision snapshot
       → bounded JSON encode → atomic file replacement → counts or sanitized error
```

The export is not an import/restore mechanism. Existing regular files may be replaced
only through the explicit native destination flow. No credentials are read to export.

## 5. Domain, persistence, and field contract

Actual definitions live in [Domain.swift](../Packages/WorkspaceCore/Sources/WorkspaceCore/Domain.swift),
[WorkspaceRepository.swift](../Packages/WorkspaceCore/Sources/WorkspaceCore/WorkspaceRepository.swift),
and the linked feature files. Values cross service boundaries as UUID-backed DTOs,
not Core Data managed objects.

| Entity | Important fields | User-visible consequence |
|---|---|---|
| Bot | id, name, description, color, shape, createdAt, hiddenAt, providerConfigID | identity does not depend on name; hide differs from delete |
| Conversation | id, kind, title, ordered memberBotIDs, lastReadSequence, nextSequence | direct/group scopes and monotonic message order/read boundary |
| Message | id, conversationID, sequence, role, speakerBotID/name snapshot, text, createdAt, replyToID, attachmentIDs, generationID | historical attribution survives edits and referenced-message navigation |
| Draft | conversationID, text, attachmentIDs, replyToID, updatedAt | switching chats/restarting retains separate drafts |
| Generation | userMessageID, attemptID, targetBotID, state, event sequence, assistantMessageID, routineRunID, roundIndex | retry/stale-event defense and per-member/routine attribution |
| Routine | ownerBotID, prompt, trigger, timezoneID, enabled, nextRunAt, providerBinding, scheduleID | explicit owner/provider and recurrence identity |
| RoutineRun | occurrence/run identity, provider binding and typed lifecycle/outcome | durable scheduling history and deduplication |
| ProviderConfig | kind, name, apiRoot, modelID, credentialReference, allowsLoopbackHTTP | metadata persists; credential value stays outside repository |
| Attachment | ID + metadata/hash + managed exact bytes | identity-safe chips/transmission/export; no original source path in export |
| UI preferences | appearance, widths, visibility | separate storage and Save/Cancel ownership from content/credentials |

### Validation and serialization facts

- Trimmed names: 1–80 characters; Bot description at most 8,000 characters.
- Avatar shapes: circle/square/drop/capsule; palette green/magenta/gray/violet/blue/orange.
- Valid editable groups: 2–6 distinct members. A group degraded by deletion can retain
  history with fewer members but cannot be treated as a normal sendable group.
- Routine interval: 5–525,600 minutes; daily hour 0–23, minute 0–59, valid timezone.
- Attachments: regular UTF-8 text; maximum 10 MiB each, 25 MiB per draft, 32 files.
- Core Data: code-defined versioned models through v4, with migration tests for earlier versions.
- JSON export: `formatVersion=3`, `sourceSchemaVersion=3`. The latter is the export DTO
  marker, not proof the Core Data store is still v3; do not substitute one version for another.
- Export arrays: bots, conversations, messages, drafts, generations, routines,
  routineRuns, providers, attachments; summary counts include raw attachment bytes.
- Export dates: Foundation seconds since 2001-01-01 UTC, NOT Unix seconds. Export cap:
  100 MiB encoded output, not a hard peak-memory limit.
- Export includes hidden data and user-authored content. Credential references/values
  are excluded by allowlist, but secrets pasted into user text are not automatically scrubbed.

## 6. Service and endpoint inventory

These are **source-level integration contracts**, not calls executed by this documentation
job and not current entitlement promises from any vendor. Native views call Swift services;
there is no app-owned REST API, Node sidecar, or localhost UI server.

| Boundary | Request / mechanism | Policy |
|---|---|---|
| UI → workspace | typed `WorkspaceRepository` read/mutation calls | serialize writes; validate identities and expected revision/state |
| Chat-compatible provider | `POST` configured root plus `/chat/completions`; JSON + SSE | explicit destination/model/key; redirect refusal; text-only parser |
| OpenAI Platform preset | source default `https://api.openai.com/v1` | API key/provider billing, not imported ChatGPT login |
| Z.ai preset | source default `https://api.z.ai/api/paas/v4` | general API template; suggested model remains editable and unverified for account access |
| 9router preset | source default `http://127.0.0.1:20128/v1` | separately managed local gateway; explicitly permitted loopback HTTP |
| Custom preset | `https://api.example.com/v1` placeholder | not a deployed endpoint; replace with a documented compatible service |
| Model discovery | `GET` normalized loopback root `/models` | explicit action; no credentials/cookies; redirects refused; 1 MiB/2,048-model bounds |
| Experimental Codex | fixed `https://chatgpt.com/backend-api/codex/responses` | imported session-only credential, no refresh, tools disabled, no arbitrary origin override; compatibility experiment, not a supported-public-API promise |
| Credential service | protected Keychain OR explicit process memory | never silent plaintext fallback; source auth file unchanged |
| Export/import selected files | AppKit security-scoped OS panels + managed copies | no home-directory scan; export isn't restore; never copy auth file into workspace |
| Computer/terminal | **no adapter in this app** | remote terminal and graphical display adapters require separate future contracts |
| Original Grok/Cursor endpoints | research identifiers in older contract only | not authorized or implemented app integration; no copied credentials |

The Codex row documents **this repository's existing code**, not advice to integrate
an undocumented service. See [its explicit limitations](CODEX-ADAPTER-CONTRACT.md).
No API keys, imported tokens, real account IDs, private network addresses, or executable
credential-bearing request examples are needed to reproduce the offline screen gallery.

## 7. Security, accessibility, and recovery invariants

1. A visible screenshot/terminal is not proof of provider success or permission to control a machine.
2. Reject stale identities/revisions at effect boundaries, not just when a dialog opens.
3. Persist send state before network dispatch; a failed save cannot result in a ghost remote request.
4. Keep source/account secrets outside workspace DTOs, fixture images, logs, and public docs.
5. Multi-recipient/mention/attachment/routine disclosure cannot be bypassed by changing the draft
   while a review is open. Consent grants the named operation, not general execution authority.
6. Cancelling can stop local work and preserve partial text; it cannot undo bytes already
   delivered to a remote provider or commands already executed by an external shell.
7. Escape/Cancel/close policies must name the affected detached form; navigation must not
   redirect an in-progress edit or overwrite another conversation's draft.
8. Expose errors honestly: loading, empty, offline, invalid credential, permission denial,
   dropped stream, conflict, corruption, export write failure, interrupted generation.
9. Native screenshots are not physical keyboard, screen-reader, sandbox-panel, performance,
   minimum-OS or notarization tests. These remain separate acceptance criteria.

## 8. Acceptance and coverage map

| Original requirement | Where the detailed behavior lives | What remains a separate gate |
|---|---|---|
| R01 native shell | W screens; screenshot catalog | complete reference-position comparison and physical resizing |
| R02 Bots/groups/search | W sidebar/picker + M editors/deletion | full keyboard/accessibility event paths |
| R03 messaging | W transcript/composer + provider/group/mention contracts | broad live-provider behavior, large-workspace timing |
| R04 files/replies/export | W file/reply surfaces + M export | real OS file selection/grants and unsupported-format expectations |
| R05 routines | M editor/run/history + routines contract | physical sleep/wake and unattended-runtime boundary |
| R06 Settings | M provider/appearance/export screens | real Keychain signing and real account breadth |
| R07 honest computer | W disconnected + terminal proposal + R reference | actual terminal/desktop integration not implemented |
| R08 templates | W/M local catalog surfaces | no live marketplace/plugin claims |
| R09 native quality/release | all screens | physical IME/VoiceOver, macOS 14 execution, Developer ID/notarization |

T01–T18 retain their full definitions in the [rewrite contract](NATIVE-REWRITE-CONTRACT.md#8-verification-contract).
This documentation task produces a detailed inventory and reproducible visuals; it does
not declare the entire experimental app release-ready or close every original T gate.

### Historical documentation notes

- `NATIVE-PROTOTYPE.md` describes the sample bundle and preserves its early test counts;
  it is not the latest durable-app feature inventory.
- Earlier feature pages contain milestone test counts. Use the fresh atlas verification
  record for this run, not the sum of historical counts.
- The old `IMPLEMENTATION.md` and `PROPOSAL.md` describe earlier ideas/prototypes. They
  are retained history, not the current source-of-truth stack or acceptance result.
- Some original requirements (for example broad text search, full keyboard picker
  navigation, or real desktop control) exceed current behavior. The per-screen entries
  identify those gaps rather than documenting proposals as accomplished facts.
- A current Settings disclosure still literally says "Attachments are not sent."
  This is stale UI copy: the confirmed text-attachment path is implemented. M12 records
  the contradiction; this documentation task does not silently alter application source
  or use that sentence as the authoritative transmission contract.

## 9. Reproduce and validate this dump

From the repository root, with macOS and the existing Swift toolchain plus Python 3:

```sh
python3 scripts/capture-screen-atlas.py --list
python3 scripts/capture-screen-atlas.py
scripts/native-app.sh test
python3 scripts/verify-screen-atlas.py
```

Capture runs only fixed sample/offline-fixture scenarios. It never runs
`codex-smoke-stdin`, opens the normal persisted workspace, fetches provider models from a
real router, or captures another application. Default outputs and logs stay in a fresh ignored local-only capture directory. The committed-ready gallery contains only
reviewed copies of original synthetic native renders; no git staging/upload is automatic.
See the [screenshot catalog](SCREENSHOT-CATALOG.md) for this run's measured results,
content-coordinate versus PNG-pixel distinction, and explicitly missing captures.
