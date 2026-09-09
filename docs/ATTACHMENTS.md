# Native text attachments and transmission contract

**Status: native UTF-8 attachment workflow implemented; remaining platform validation is open.**
The app copies explicitly chosen text files into its managed workspace, restores removable
composer chips and transcript metadata, and requires a fresh destination/content-bound
confirmation before transmitting files from a draft, recent context, an older reply or retry.
Images and other binary formats are unsupported. This does not complete all R04/R09 gates.

## Storage decision (ADR-ATTACHMENT-01)

Use the `Attachment` entity introduced in Core Data v3 (preserved in v4) with immutable metadata and a separate binary
content attribute. The external-binary-storage hint is enabled, but physical file
placement remains Core Data's implementation detail. No original absolute path,
bookmark, app-managed relative path, or physical backing-file URL is persisted or
exposed by the API. Metadata records the conversation UUID, stable attachment UUID,
safe display filename, `text/plain`, byte count, SHA-256 and creation time.

This replaces the proposed `appManagedRelativePath` field in the
[rewrite contract](NATIVE-REWRITE-CONTRACT.md), not its user-visible requirements.
One repository save/rollback boundary owns exact bytes, references and the draft.
A manually managed UUID-file directory would introduce a database/filesystem
dual-write, orphan-reconciliation and path-race protocol without a current benefit
at the 10 MiB/file and 25 MiB/draft limits. Revisit separate streaming storage if
larger files become an explicitly accepted requirement; do not add a second store
merely for a path-shaped DTO field.

Export v3 is a self-contained JSON manifest with an `attachments` array containing
metadata and base64-encoded **exact bytes**, once per referenced attachment. This
satisfies manifest-plus-safe-content packaging without ZIP dependencies or exposing
the internal storage layout. It is not an import/restore feature or encrypted backup.

## Repository contract

- `AttachmentContent` validates strict UTF-8, safe filename, content hash and byte
  count. Binary/image files are unsupported. Text rejects control characters except
  tab, CR and LF; non-ASCII text is retained, not normalized into different bytes.
- Limits: **10 MiB per file, 25 MiB total and 32 ordered unique references per
  draft/message**. Filename validation is independent of content decoding.
- `saveDraftWithAttachments` saves new content and the complete draft atomically.
  Supplied new IDs must be referenced by that draft and belong to its conversation.
  Repeating an identical ID/payload is safe; reusing an ID for different content is
  rejected. Validation/save failure rolls back the complete operation.
- Metadata lookup does not return bytes and currently accepts at most 32 ordered
  unique IDs per call; future transcript hydration must batch per message rather
  than treat that as a whole-transcript limit. `attachmentContent(id:)` verifies
  content before returning it. `WorkspaceSnapshot` remains free of attachment payloads.
- Repository-level attachment-only messages are valid. User-message creation,
  initial generation and matching draft clear commit together; text, reply target
  and ordered attachment IDs must all match before a draft is cleared.
- Removing references prunes only removed-ID candidates after scanning surviving
  message/draft references. Ordinary text edits with unchanged IDs skip this scan. Bot deletion includes the exact removable attachment IDs and total
  byte count in confirmation. Retained group history/content is not deleted with a
  former member; missing/corrupt affected content fails closed.
- Historical model v1 and v2 definitions remain immutable. Explicit validated
  migrations now produce schema v4 (which preserves the v3 attachment format), retain existing payloads/routine history, and use
  the existing replacement/recovery boundary rather than silently resetting data.

## Native file ingress and draft lifecycle

- The **+** button opens a cancellable multi-file `NSOpenPanel`. The sample preview
  does not read files. No home scan, automatic credential-file discovery or retained
  original path/bookmark is involved.
- Reads run off the main actor with balanced security-scoped access. A bounded file
  descriptor read uses `O_NOFOLLOW`, `O_NONBLOCK`, regular-file/size checks and
  before/after identity, size and timestamp checks. Final-component symlinks, folders,
  devices, unsupported types, invalid UTF-8 and unsafe filenames are rejected.
  This does **not** prove protection against every hostile ancestor-directory race.
- One chooser/import owns the operation synchronously. The selected conversation is
  frozen when it starts; navigating elsewhere never retargets the copy. Accepted reads
  and saves are joined on quit/reconnect; an unaccepted chooser is cancelled.
- All new files and the full draft go through the existing sole, versioned draft writer.
  A failed batch leaves no new references/content; concurrent text edits survive. If a
  later unrelated draft save fails after the file transaction committed, committed
  chips remain and the storage error is surfaced rather than pretending to undo it.
- Draft chips show names and exact byte counts, support removal, and survive restart.
  Transcript chips are read-only metadata. Missing metadata is visible, not silently
  rendered as an empty message. Bytes are not fetched merely to render a chip.
- Removing a draft reference never removes content still referenced by a message.
  Managed content is independent of subsequent edits/removal of the original file.

## Provider transmission and consent

`GenerationCoordinator.attachmentTransmissionPlan` and its retry counterpart prepare
an ordered, unique disclosure without credential reads, generation writes or network.
The plan includes conversation/target bot, full provider configuration, ordered file
IDs/names/hashes/bytes, context count and a deterministic request fingerprint. It is
memory-only and contains neither file bodies nor actual credentials.

The native confirmation names the API root/model/conversation/bot and every file,
including files being **retransmitted from context**. Cancel has no provider effects.
Send recomputes the plan before credentials; a changed draft, target, provider, model,
file or included context requires cancelling and reviewing a new disclosure. The
fingerprint excludes only incidental new-command UUID/time, not semantic content or
context identity. A caller cannot bypass this by omitting the optional consent argument.

[Group rounds](GROUP-ROUNDS.md) add a mandatory ordered aggregate disclosure, including
text-only rounds. It binds every target and request, not merely the first bot's file list.
All members use the same captured history and file bytes, with each file sent once **per
member request**; selecting three members can transmit the file three times to the
displayed provider. Every target plan is compared before the first credential read.

Preparation validates exact managed bytes, strict UTF-8, hash and conversation scope.
The request has at most **32 unique files and 25 MiB total raw file bytes** across draft,
up to 100 recent messages and any explicitly selected older reply. Limits fail visibly;
files are not silently truncated. Each file body appears once per request, with later
references by identity. Files remain untrusted text, never executable HTML/tools or
system instructions. Included non-user messages carrying file references are rejected
before transmission rather than presenting file text as assistant-authored content.
Both Chat Completions and the experimental Codex text adapter use
this path; it is not an image upload capability.

After consent validation the request uses the same immutable prepared turns, rather
than rereading different bytes after credential access. Later edits cannot alter an
already accepted request, and a newer draft is not cleared by an older send. Provider
privacy terms/charges apply; a transmitted request cannot be unsent.

**Routine authorization remains text-only.** A routine whose included context has files
records a typed blocked outcome before credentials/network. The interactive file sheet
does not silently broaden previously saved routine authorization. Unselected unsent
files in another draft are not transmitted by unrelated text sends.

Export includes exact stored content and is **not secret-scrubbed**. Deletion discloses
counts/bytes. Neither logical deletion nor export promises secure erasure or encryption.

## Verification and remaining gates

Synthetic tests cover bounded/type/UTF-8 importer failures, cancellation, frozen chat
ownership, atomic multi-file copy, concurrent edits, save rollback, removal/reopen,
explicit send consent/cancel/drift, retries, recent and older reply context, request
limits, wire formats and routine blocking. See the current counts in
[durable workspace evidence](DURABLE-WORKSPACE.md#verification-evidence).

`attachment-smoke` uses only temporary synthetic files/stores and offline credential/
provider fixtures. It exercises real bounded file reading, managed-copy restart, native
chips and confirmation rendering, Cancel with zero credential/provider calls, and an
explicit confirmed send. It does not automate physical clicks in the OS file picker.

Remaining validation includes real selected-file sandbox grants, native keyboard and
VoiceOver interaction, hostile filesystem races, power-loss durability and macOS 14
runtime compatibility. The complete R01–R09 / T01–T18 finish line remains active.
Images and routine file authorization need separate capability/consent contracts.
Explicit reference removal still scans persisted message/draft payloads; current
reference validation rehashes up to 25 MiB of content. Those latency costs remain
unmeasured. Export capture/JSON encoding and reference scans are not hard peak-memory
or native 10k-message performance proofs; see [export limits](WORKSPACE-EXPORT.md).
