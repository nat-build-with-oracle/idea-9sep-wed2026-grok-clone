# Native message replies

Implemented in the durable SwiftUI/AppKit workspace and the sample-only preview.
This advances R03/R04/UI-04; it does not complete attachments, export, routines,
native accessibility certification, or the full rewrite contract.

## User flow

- **Reply** on a nonempty user/assistant message selects that message without sending
  anything or changing the draft text. Event rows are not reply targets.
- The composer shows the recorded sender and a bounded, whitespace-normalized
  excerpt. **Cancel reply** removes only the reference, not the draft text.
- References belong to their conversation. Switching chats does not carry a reply
  selection into another chat, and a late lookup cannot replace a newer selection.
- Selecting the reference opens its original message. Older pages are loaded back
  to that message without removing already visible or streamed rows. Navigation
  during the lookup cancels its authority to scroll the newly selected chat.
- **Copy** copies one message's text. The old bulk conversation-copy control has
  been removed; replying does not copy anything to the clipboard.

```text
Reply action → same-conversation parent lookup → text + reply ID in local draft
                                                    │
                                      debounce / switch / close → atomic save
                                                    │
Send → capture text + parent + draft version → validate parent before effects
        │                                           │
        │                         persisted user message + queued generation
        │                                           │
        │                                  explicit provider request
        └─ newer draft/reference survives ← compare original version on return

Restart → restore text + parent ID → resolve preview (no provider call)
Retry   → reuse original persisted user message and its original reply parent
```

## Persistence and request contracts

`Draft.replyToID`, `Message.replyToID`, and `SendCommand.replyToID` already existed
in the v1 domain. This feature connects them to native presentation without a
schema change. References must resolve to a nonempty, non-event message in the
same conversation. Missing/foreign targets fail instead of silently becoming an
unrelated send. Failed writes and missing providers retain the draft/reference.

Draft versioning includes reply choices, not only text edits. The repository's
atomic matching-draft clear compares text and parent identity; the presentation
store also keeps a newer choice made during submission. Before replacing a
repository, `connect()` joins old draft writers and flushes the old store, then
reloads document-scoped state. It does not copy old drafts into a new store.

Provider context contains the normal recent-message window and the explicit
parent exactly once. An older parent outside that window is additionally included
with its original role and text. Trusted application metadata identifies its
non-system context-turn index; parent content is not promoted to a system
instruction. The representation also works with the Codex adapter's separate
instructions/input mapping. Existing request-size and transport limits still
apply; this does not add tools, attachments, or a private endpoint integration.

Previews use recorded speaker names, not a renamed bot's current display name.
Pending and unavailable parents have distinct states. Failed lookups are cached
rather than repeated for every stream update, and explicitly reloading a
conversation retries unavailable references. Active assistant parents may refresh
as their text streams. Preview resolution performs repository reads only.

## Verification

```sh
scripts/native-app.sh test
scripts/native-app.sh reply-smoke
scripts/native-app.sh reply-smoke --small
```

The offline native smoke uses only its own temporary workspace. It sends a fixture
message, selects a reply, closes/reopens the actual SQLite store, checks restored
text/reference/sender, sends the restored reply through a validating fixture
provider, verifies its persisted reference and matching-draft clearing, then
renders a new unsent reply draft. It does not read account credentials, contact a
live endpoint, or touch the normal workspace.

Regression coverage includes the previously reproducible loss of a restored
reply reference after editing its text; old-parent context; invalid targets before
credential/provider effects; retry; native restart, cancellation, stale lookups,
failed writes, same-text/new-parent races, repository switching, overlapping page
loads, and scoped presentation labels.

Native fixtures exercise the real service/rendering path, not automated mouse or
VoiceOver interaction. Large backfills still need the full 10k-message performance
budget, and IME/keyboard/VoiceOver/XCUITest coverage remains an explicit open gate.
