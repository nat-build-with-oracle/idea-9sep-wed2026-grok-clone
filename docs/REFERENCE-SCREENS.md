# Original reference screens — observation archive and ASCII layouts

This archive preserves the screen/layout knowledge from the supplied Grok Bot images.
It does **not** describe every hidden page in that proprietary app, infer undocumented
backend behavior, or treat its account/VM services as part of BotWorkspace.

Eight private source images were located and inspected: three original desktop
screenshots, four later computer/terminal screenshots, and the previously retained
local reference image. Their exact local paths, dimensions and SHA-256 hashes
are in an ignored local-only reference index; a local HTML image
viewer sits alongside it. These files are ignored. Private screenshots stay in place,
unchanged; the public atlas uses our own synthetic native renders instead.

**R** IDs below name observed screens/surfaces, not filenames. **P** IDs identify
private source files in that index. Names/message contents are replaced with neutral
labels in the ASCII; no private conversation needs to be copied to explain the layout.
See the [implemented W/M catalogs](FEATURE-ATLAS.md#start-here) for actual product behavior.

## Reference screen inventory

| ID | Observed screen/surface | Source images | What the image actually proves |
|---|---|---|---|
| R01 | Three-column conversation workspace | P01, P04, P08 | sidebar + transcript + inspector geometry and visible controls |
| R02 | New-chat recipient picker | P02 | Create new Bot / Create group chat / existing Bot entries |
| R03 | New-group recipient selection | P03 | group context and add-to-group recipient list; not final creation behavior |
| R04 | Computer thumbnail in inspector | P01, P04, P05, P08 | a desktop-like thumbnail, owner label, surrounding routines |
| R05 | Expanded computer connecting state | P06 | dimmed workspace, centered Connecting, expansion controls |
| R06 | Expanded Linux desktop / terminal window | P07 | graphical desktop image with a terminal and task-teaching affordance |
| R07 | Routine activity in conversation and inspector | P01, P04, P08 | routine entries and timeline event labels; not scheduler implementation |
| R08 | Dismissed question/prompt state | P08 | a message with a visible Dismissed badge; not its full workflow |

## R01 — reference conversation workspace

```text
+-------------------------+--------------------------------+---------------------+
| macOS controls       +  | Bot avatar + name       share  | settings   collapse |
| Search                  |--------------------------------|---------------------|
| selected Bot · time     | routine event                  | computer thumbnail  |
| last-message preview    | assistant message bubble       |                     |
| Bot B · time            |   reaction / reply / more      | Bot's screen        |
| Bot C · yesterday       | NEW unread divider             | Routines          + |
| Bot D ...               | time separator                 | routine name        |
|                         | subsequent reply bubble        | recurrence label    |
|                         | user bubble aligned right      |                     |
|                         |                                |                     |
| Marketplace             | [+] Message Bot          [mic] |                     |
| Account avatar + name   |                                |                     |
+-------------------------+--------------------------------+---------------------+
```

**Observed:** bot avatars use different colors/shapes; sidebar previews and relative
message times; rounded user/assistant bubbles; date separators; scrollbars; bottom
composer; a share/export-looking icon in the conversation header; a microphone-shaped
control; separate details column. These are visual observations, not verified click actions.

**BotWorkspace mapping:** W shell/sidebar/transcript/composer/inspector. The native
app has real window controls, original avatars, persistence and provider state. It does
not copy the pictured account, chat history, microphone implementation or desktop feed.
A visible reaction icon is not proof that our app implements reactions; see message menus
in the W catalog for the exact current actions. The current JSON export flow is specified
independently, not reverse-inferred from the reference share icon.

## R02 — new-chat recipient picker

```text
+----------------------+------------------------------------------------------+
| Sidebar              | To: Search or create Bots                         ×  |
| Search               | +--------------------------------------------------+ |
| + New chat selected  | | + Create new Bot                                 | |
|                      | | group icon · Create group chat                   | |
| existing chats       | | avatar · Bot A                       New chat    | |
|                      | | avatar · Bot B                                   | |
|                      | | avatar · Bot C                                   | |
|                      | +--------------------------------------------------+ |
| Marketplace          |                                                      |
| Account              | [+] Message Bot                               [mic] |
+----------------------+------------------------------------------------------+
```

The screenshot shows the picker replacing the central transcript while the sidebar
remains. It does not establish keyboard-arrow semantics, matching rules, duplicate-name
handling, creation validation or persistence. The independent native picker contract
specifies those behaviors from source, including any current keyboard gaps.

## R03 — new-group selection

```text
+----------------------+------------------------------------------------------+
| Sidebar              | To: Search or create Bots                         ×  |
| + New group chat     | +--------------------------------------------------+ |
|                      | | avatar · Bot A                 Add to group chat | |
| existing chats       | | avatar · Bot B                                   | |
|                      | | avatar · Bot C                                   | |
|                      | | avatar · Bot D                                   | |
|                      | +--------------------------------------------------+ |
|                      |                                                      |
| Account              | composer retained at bottom                          |
+----------------------+------------------------------------------------------+
```

Observed: an existing recipient row has an add-to-group affordance and the sidebar
indicates a new group. The image alone does not prove member minimum/maximum, recipient
order, final confirmation, or response sequencing. Our 2–6 member validation, ordered
rounds and identity-safe mentions come from explicit implementation contracts, not this image.

## R04 — inspector computer thumbnail

```text
+-----------------------------------+
| settings                   expand |
| +-------------------------------+ |
| | small desktop / terminal view | |
| | desktop background + dock     | |
| +-------------------------------+ |
|           Bot's screen            |
| Routines                        + |
| clock  Routine                    |
|        Every N hours              |
+-----------------------------------+
```

The thumbnail is a **graphical desktop image**, not merely a terminal byte stream.
P05 is a close view of this area. There is no proof in the images of codec, frame rate,
QEMU configuration, VNC, SPICE, WebRTC, auth tokens or a reusable public endpoint.
BotWorkspace's corresponding region is currently a truthful disconnected card.

## R05 — expanded connecting overlay

```text
+--------------------------------------------------------------------------+
| native window controls                         [Teach a task] [collapse]  |
| background workspace dimmed                                              |
| +----------------------------------------------------------------------+ |
| |                                                                      | |
| |                                                                      | |
| |                         avatar / spinner                             | |
| |                            Connecting                                | |
| |                                                                      | |
| |                                                                      | |
| +----------------------------------------------------------------------+ |
+--------------------------------------------------------------------------+
```

Observed: a large bordered dark computer surface over a dimmed workspace and a centered
connection label. Unknown from this still image: timeout, cancel/retry rules, destination
selection, reconnect policy, credential exchange, focus capture, or whether background
streams remain active. Those must be explicitly designed for any independent adapter.

## R06 — expanded desktop with terminal window

```text
+--------------------------------------------------------------------------+
| workspace dimmed behind                 [Teach a task] [collapse]         |
| +----------------------------------------------------------------------+ |
| | +--------------------------------------------+                       | |
| | | Terminal title                   _ [] ×    |                       | |
| | | menu bar                                   |                       | |
| | | shell prompt + command/output              |   desktop wallpaper   | |
| | | cursor                                     |                       | |
| | +--------------------------------------------+                       | |
| |                                                                      | |
| |                     browser / tools / terminal dock                   | |
| +----------------------------------------------------------------------+ |
+--------------------------------------------------------------------------+
```

The terminal is **inside the remote desktop**. That differs from embedding a standalone
terminal renderer without a desktop/window manager. The visible Teach a task control
does not establish recording, automation, permission or replay semantics; none is
implemented or authorized by this reference. For the proposed terminal alternative,
see [the computer/terminal contract](COMPUTER-TERMINAL-CONTRACT.md).

## R07 — routine evidence inside chat

```text
Transcript                           Inspector
----------------------------------   ---------------------------
Created routine · Routine name       Routines                  +
assistant response                   clock · Routine name
(time separator)                             Every N hours
later scheduled-looking response
Updated routine · Routine name
```

The screenshots contain recurring-looking responses and routine event labels. They
cannot establish backend scheduling, timezones, DST, missed-run behavior, whether an
app is running, or cancellation semantics. Our app instead has a specified awake-only
scheduler, explicit provider/owner consent, and durable run history. No weather data
from these private conversations is a reusable fixture or a verified provider result.

## R08 — dismissed question/prompt

```text
+-----------------------------------------------+
| introductory assistant message                |
+-----------------------------------------------+
+-----------------------------------------------+
| question text                    • Dismissed   |
+-----------------------------------------------+
```

Only the final visual badge is observed. The trigger, dismiss action, input form,
notification policy and durable state are not supplied. There is no equivalent current
BotWorkspace feature claim; any future prompt/question flow needs its own contract.

## Feature parity and intentional differences

| Reference detail | Native app status | Documentation consequence |
|---|---|---|
| Dark three-pane messaging | implemented with Light/System alternatives | W shell/appearance maps geometry, not private content |
| Recipient dropdown and group affordance | independently implemented picker | validate against M/W code, not assumed reference keyboard behavior |
| Colored geometric avatars | original local implementation | no extracted proprietary assets |
| Message reply affordance | implemented local reply workflow | persistence and jump behavior separately tested |
| Reactions / dismissal chip | no parity claim | record as observed, not shipped |
| Mic / voice | no voice backend | no fake operational microphone |
| Routine labels | independent native scheduler/history | no inherited 24/7 service claim |
| Computer thumbnail/expanded desktop | disconnected current app | C contract remains proposed for live integration |
| Teach a task | reference-only affordance | no recording, automation or replay implemented |
| Account display | independent local display profile | no imported account session or private credentials |
| Marketplace | local synthetic template catalog | no assumption of a remote plugin store or subscription |
| Header share icon | independently specified JSON export | do not infer original app's share transport |

## Archive integrity and privacy

- Keep the original private images unchanged. The local index records hashes/dimensions
  and labels each image; it does not rename a reference capture into an app screenshot.
- Public docs contain neutral ASCII, descriptions and original synthetic native renders.
  No user names, message history, reference account avatars or extracted bundle images
  are required to build the app or view the public gallery.
- No hidden proprietary screen or private API function is claimed from an unverified
  bundle string. The earlier native contract records endpoint research only as a boundary,
  not an executable integration recipe.
- Private session memory and infrastructure details are not included in the public
  documentation. Only current app source establishes implemented behavior.
