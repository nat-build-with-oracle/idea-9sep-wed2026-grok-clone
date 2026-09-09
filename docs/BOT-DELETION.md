# Confirmed bot deletion and group repair

The durable native app offers **Delete Bot…** in a direct conversation's context
menu. Hide/unhide stays separate and reversible. Development and smoke verification
use isolated synthetic workspaces only, never the user's saved workspace.

## Confirmation and affected records

The native sheet names the bot and counts its direct conversations, messages,
drafts, generation records, owned routine definitions, run history, and unreferenced attachment counts/bytes. It also counts active or
queued affected replies, lists groups with remaining member counts, and warns when
a group will need repair. Cancel/Escape closes without deleting. There is no default
Return shortcut for the destructive action; **Delete Bot** is explicit.

Pending composer drafts are flushed before loading the impact. Confirmation is tied
to the captured bot identity, not the current sidebar selection. One deletion can be
accepted at a time. A stale or failed operation disables confirmation until **Review
Current Impact** loads a fresh plan. Export is a separate action: cancel first to
[export a copy](WORKSPACE-EXPORT.md). Deletion cannot be undone by the app.

| Record | Policy |
|---|---|
| Bot and its direct conversations | Permanently removed; identity is never reassigned |
| Direct messages, drafts, generation records | All removed, not just the loaded page |
| Owned routines | Definitions and run history removed; unrelated owners' routines stay |
| Group conversations | Retained with this bot removed from future membership |
| Group messages/drafts/generation history | Retained, including partial replies and immutable speaker-name snapshots |
| Shared provider configuration and credentials | Not deleted or read by deletion |
| Direct attachment content | Delete only IDs with no surviving message/draft reference; confirmation includes count and total bytes |
| Missing/corrupt affected attachment content | Reject deletion rather than silently lose or miscount content |

The [routine occurrence ledger](ROUTINES.md), introduced in schema v2, is retained in schema v3. Confirmation
includes owned history and active claims, even claims still waiting for credentials before a
generation exists. Native routine execution controls are connected with explicit consent and awake-only scheduling.
The [attachment foundation](ATTACHMENTS.md) stores exact text bytes under the same transaction boundary;
shared/surviving references protect those bytes from deletion.

## Transaction and concurrency contract

`WorkspaceRepository.botDeletionPlan(botID:)` captures the affected identities and
counts in one serialized Core Data operation. `BotDeletionPlan.hasSameContent(as:)`
compares destructive structure—bot name, direct record IDs, routine/run IDs, deleted attachment IDs/total bytes, and group
titles/remaining ordered membership—not the global workspace revision. Unrelated
provider edits or another conversation's stream do not invalidate consent. Content
changes within an already counted message/draft remain part of that record; this is
not a byte-for-byte content checksum confirmation.

`GenerationCoordinator.deleteBot(expected:)` validates the current plan before
cancelling affected work. Newly active/queued replies require fresh confirmation;
naturally completed ones need not. Cancellation scope comes from the repository,
not caller-supplied extra conversation IDs. Per-bot/conversation operation epochs
invalidate sends/retries suspended before deletion, and affected queued jobs cannot
start while their siblings are stopped. Already running unrelated conversations are
not cancelled. Queue starts may be briefly suspended while deletion is coordinated.

Affected transports are cancelled and awaited before physical deletion. The
repository transaction recomputes destructive impact and requires affected generation
records to be terminal, then removes all direct records/routines/bot and updates
group membership in one save. Save failure rolls back this transaction. Earlier
provider cancellation is not an undoable database change: if deletion later fails,
records remain but replies may already be stopped and require explicit Retry.
Cancelling a request also cannot undo work already performed by a remote provider.

Quit and repository reconnect join an accepted deletion before closing/replacing its
store. A failure during the quit wait keeps the app open. Cancelling a pending impact
lookup or reconnecting cannot reopen a stale sheet. Success clears only deleted
presentation caches and targets; a post-commit refresh error does not falsely say
the deletion failed. Late transcript callbacks cannot repopulate a deleted row.

## Readable groups with zero or one member

Removing members can leave a group with fewer than two available bots. Its history
and draft stay readable. The composer shows **Group needs repair** and an **Edit
Group…** action. Sending and retrying are rejected at both native and core boundaries
before credential reads/transmission. Historical replies from the deleted bot remain
attributed but cannot be retried as that deleted identity.

Normal group creation and replacement still require 2–6 distinct valid members.
The profile CAS operation accepts an exact existing 0/1-member baseline so the native
editor can repair it; stale baselines still reject. Existing hidden members may be
retained under the ordinary profile-editing rules. Close/reopen preserves this state.

## Verification and limits

```sh
scripts/native-app.sh test
scripts/native-app.sh deletion-smoke
scripts/native-app.sh deletion-smoke --small
```

Original deletion milestone suite: **291 tests passed** (153 core + 138 native), including 8
repository deletion tests, 8 coordinator deletion tests and 12 native deletion tests.

Repository tests cover more than 100 direct messages, exact row removal, zero/one
member group preservation and repair, restart, rollback, stale impact, active-work
rejection, unrelated revisions, providers and unsupported attachments. Coordinator
tests cover affected active/queued cancellation, unrelated streams, stale/new activity,
paused preparation/retry, failure and explicit retry, and no credentials for degraded
groups. Native tests cover identity-bound confirmation, draft/cache preservation,
Cancel, stale reload, zero-member groups, reopen/repair, and accepted close/reconnect.

The sandboxed native smoke creates two bots and a group, uses an offline provider
fixture to persist group history, renders the real confirmation sheet, invokes its
controller action, reopens SQLite and verifies the retained group/history/provider
and removed bot/direct conversation/routine. It captures the narrow repair UI too.
It does not click the physical context menu/button through XCUITest, prove VoiceOver
focus restoration, simulate disk-full/power loss, or certify macOS 14 runtime behavior.
No live provider or real user workspace is used. Signing remains local/ad-hoc.

The full [rewrite contract](NATIVE-REWRITE-CONTRACT.md) remains in progress.
