# Ordered group replies

An explicitly selected group can ask **one to six current members**, in the displayed order.
One user message is stored. Each selected bot has its own attributed generation and reply;
the app does not pretend a single response is a team of independent workers.

## User contract

- Selection order is reply order. The composer shows the recipients, and the round
  confirmation lists every recipient in full, the provider/model, context and any files.
- Multiple recipients mean **multiple separate provider requests**, potentially with separate
  charges or quota usage. Review is required even for a text-only round. No request starts
  while this confirmation is merely open.
- Every member receives the **same pre-round conversation context and text attachments**,
  plus its own bot instructions. Later members do not receive earlier members' replies from
  this round. This is an ordered set of independent answers, not a recursive bot conversation.
- There is one active request per conversation and at most three across the app. A later
  send in the same conversation queues behind the entire accepted round.
- A provider failure is visible on that member. Other already-approved members continue
  in order; failed members are not automatically retried.
- **Stop round** cancels the active and remaining queued members of that user message.
  Completed replies and persisted partial text remain. Unrelated user messages are not stopped.
  Cancellation cannot undo bytes already sent or provider charges already incurred.
- **Finish or Stop the round before Retry.** Retry targets only the chosen
  failed/cancelled/interrupted member. It retains the original
  user message and earlier output; completed siblings are not resent. File retries still
  require a fresh exact disclosure.
- Relaunch marks unfinished work interrupted, with manual retry only. Nothing is auto-replayed.

[Draft mentions](GROUP-MENTIONS.md) can instead select the ordered recipients. Every mention
send requires review, including one recipient; malformed or unresolved mentions never fall
back to manual recipients. Binary/image transmission and recursive agent/tool execution
remain unsupported.

## Flow and persistence

```text
ordered recipients + draft
  -> capture pre-round transcript and file bytes once
  -> derive one request fingerprint per recipient
  -> show aggregate disclosure (no credentials, no transport)
  -> user confirms
  -> recapture; compare every fingerprint and target order
  -> authorize every request
  -> atomic revision-guarded save
       one user message
       N queued generations, indexed 0 ... N-1
       captured target names
       clear only the matching draft
  -> enqueue N jobs contiguously
       member 1 -> member 2 -> ... -> member N
         completed / failed per member

Stop round
  -> invalidate round epoch + suspend dispatch (before any await)
  -> remove queued siblings + cancel active transport
  -> atomically cancel nonterminal siblings
  -> join active transport + resume unrelated dispatch
```

`Generation.userMessageID` is the round key. Optional `roundIndex` and
`targetSpeakerNameSnapshot` fields are added to the existing Codable generation payload;
the Core Data model stays **v4** and JSON export stays **v3**. Older payloads decode those
optional fields as nil. A multi-recipient user message has no singular `generationID`;
assistant messages retain their generation link. No separate Round entity or migration is needed.

The aggregate `RoundTransmissionPlan` contains ordered request metadata/fingerprints, not
credentials or file bytes. The coordinator compares the whole plan before reading a credential.
If context, members, bot instructions, files, provider/model or selection order changes, review
fails closed. A workspace mutation during authorization rejects the revision-guarded save;
the draft remains and zero requests start. The user can review the updated round again.

If a Stop save fails, transport still stops and queued siblings are never reinserted. The
unpersisted cancellation remains available for explicit Stop retry or orderly shutdown recovery.
The app reports the persistence failure rather than claiming the stored statuses are cancelled.

## Verification boundaries

- `GroupRoundRepositoryTests`: atomicity, identities/reservations, attachments/drafts,
  ordering, rename-stable attribution, legacy payload decoding, restart and terminal guards.
- `GroupRoundCoordinatorTests`: frozen context and one file/history read per preparation,
  whole-round consent before credentials, zero-effect preparation/save failures, queue order,
  cancellation races/save recovery, per-member failure and retry.
- Native tests and offline visual smoke cover the selection/confirmation/send/stop integration;
  they do not prove provider account entitlement, a real unlocked-window keyboard/VoiceOver
  session, notarization or runtime compatibility on an actual macOS 14 host.

Existing [provider](PROVIDER-CORE.md), [attachment](ATTACHMENTS.md),
[credential](PROVIDER-SETUP.md) and [unread](UNREAD-CONVERSATIONS.md) boundaries continue to apply.
