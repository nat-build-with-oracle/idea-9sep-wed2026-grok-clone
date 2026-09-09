# Conversation activity and read state

The native sidebar shows a persisted latest-message preview, timestamp and unread
**assistant reply** count, including conversations whose transcript has not been
opened. The count is exact across history, not just the loaded 100-message page;
the visual badge caps at `99+`, while its accessibility value includes the full count.
User messages and retry/event rows do not count as incoming replies. Hiding a bot
does not itself change its read state.

## Read acknowledgement contract

- Merely loading or selecting a conversation is not acknowledgement.
- The app must be active and the main workspace window must be visible, key and
  not minimized. Settings, pickers, editing/confirmation sheets and file dialogs
  do not silently acknowledge an obscured conversation.
- The transcript's rendered bottom anchor must be inside the viewport (only a
  half-point layout-rounding tolerance). The separate 50pt auto-scroll tolerance
  is **not** permission to mark read.
- The rendered latest message's identity, sequence and UTF-8 text length must
  match the atomic activity snapshot. Streamed text only appends; comparing length
  prevents a final delta to the same sequence from being acknowledged while the
  older text is still rendered.
- A nonterminal generation in that conversation delays automatic acknowledgement.
  This keeps a partial message from being marked read just before the user leaves
  and additional text arrives on the same sequence. Completed, failed, cancelled
  and interrupted replies can be acknowledged when visible.
- The write captures the exact observed sequence before awaiting the repository.
  It never substitutes a newer sequence after navigation or a newly arrived reply.
  Existing repository validation enforces range and monotonic watermarks.
- Badges clear only from a successfully returned repository snapshot, not optimistically.
  Failed writes/refreshes show a separate **Retry read status** action. A later
  snapshot proving the watermark reconciles a previously failed refresh.
- Accepted writes finish before repository replacement or closing. Context and
  revision checks reject stale projections without redirecting an old read to a new chat.

## Persistence and query boundary

Core Data **v4** adds an indexed `messageRole` field. The v1/v2/v3 model definitions
remain immutable; legacy stores migrate through the existing staged validation,
replacement and recovery path. Roles are backfilled from message payloads in the
staged destination, before replacing the source. Existing conversation IDs,
read markers, drafts, routine history and attachment content remain intact.
The independent workspace **JSON export format stays v3**.

One serialized snapshot returns conversations, generations and `ConversationActivity`
values. Each conversation requires a latest-message fetch limited to one row and
an indexed assistant-count query after its watermark—not a full transcript load.
Previews contain at most 160 graphemes; attachment-only messages use a generic
label rather than opening file content. The latest one-row query still decodes that
message's payload; this is not a claim of zero text I/O or bounded generation history.

## Verification

```sh
scripts/native-app.sh test
scripts/native-app.sh unread-smoke
scripts/native-app.sh unread-smoke --minimum
# Explicit controller/render fixture for a locked console; not real-focus evidence:
scripts/native-app.sh unread-smoke --minimum --fixture-foreground
```

Core tests cover exact counts beyond 100 messages, role exclusion, Unicode preview
limits, same-sequence delta metadata, monotonic/range-checked read writes, save
failure and legacy migration/recovery. Native tests cover background/scrolled-back
gates, rendered-final-text checks, draft preservation, stale snapshots, concurrent
arrival/navigation, failed-refresh recovery and joined close/reconnect.

The default, strict native smoke launches through macOS Launch Services (`open -n -W`) rather than
assuming a direct CLI child can become foreground. It uses synthetic conversations
and actual main/Settings window focus,
renders dark/light unread rows, acknowledges the foreground rendered transcript and
checks read/unread/draft retention after reopening the store. **That real-focus gate
remains unverified on this run:** the console reported locked, and both app/main/Settings
key-state checks correctly stayed false. The separately labelled `--fixture-foreground`
mode injects foreground state only inside the isolated verifier and exercises native
rendering, automatic receipt dispatch and persistence; its output explicitly reports
`actualWindowFocusTested=false`. It is not a replacement for the strict focus gate.
Neither mode automates
physical mouse, keyboard, VoiceOver or OS-space switching. No provider credentials
or real user's workspace/preferences are used.

This advances UI-02 and persistence coverage. Full R01–R09/T01–T18 acceptance,
macOS 14 runtime, native 10k-message/50Hz Instruments performance and release
signing/notarization remain governed by the [original contract](NATIVE-REWRITE-CONTRACT.md).
