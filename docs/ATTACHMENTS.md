# Attachment foundation and remaining native workflow

**Status: storage milestone, not finished R04.** This source release adds app-managed
UTF-8 content persistence, migration, export and reference-safe cleanup. It does
**not** yet let users choose/remove files or transmit their content to a provider.
The existing attachment button still explains that file controls are unavailable.

## Storage decision (ADR-ATTACHMENT-01)

Use a Core Data v3 `Attachment` entity with immutable metadata and a separate binary
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
  migrations produce schema v3, retain existing payloads/routine history, and use
  the existing replacement/recovery boundary rather than silently resetting data.

## Current native/provider behavior

Native text edits, flushes and reconnects preserve existing attachment IDs. Existing
draft/transcript references are disclosed as stored-attachment counts rather than
rendered as silently empty text. Export warns that exact stored file content is
included and is **not secret-scrubbed**. Deletion names attachment counts and bytes.

`GenerationCoordinator` rejects new attachment sends, original-message retries,
attachment-bearing recent context and explicitly selected older attachment replies
**before credential reads, generation mutation or provider calls**. Attachment-only
messages are checked before filtering empty text. Routine runs record a typed
blocked outcome rather than silently omitting files or broadening saved consent.
Unselected unsent draft files are not read or transmitted by unrelated text sends.
Ordinary text-only conversations remain usable.

## Required next integration — not deferred out of v1

1. Native, explicit selected-file ingress: bounded regular-file reads, security-scope
   lifetime, cancellation, symlink/type/size checks, exact managed copy and no paths
   retained. No credential-file discovery, home scan or automatic file read.
2. Persistent removable draft chips and transcript metadata, attachment-only send
   affordance, single-flight chooser, frozen conversation ownership, and accepted
   import work joined before quit/reconnect. Use the existing serialized draft
   writer; do not race a second independent draft-save path.
3. Preflight selected/recent/reply file content before credentials/network. Disclose
   destination/model, ordered IDs/names/hashes/bytes and conversation; bind explicit
   confirmation to that exact request. Changed content/destination needs fresh
   consent. File content stays untrusted user text, not system instructions or tools.
   Decide routine file authorization explicitly; do not reuse existing text consent.
4. Synthetic-file native smokes at desktop/narrow sizes and failure/race tests for
   selection, cancellation, original-file changes, draft switching, save failure,
   consent drift, retry, export, deletion and restart. Validate real sandbox grants
   and accessibility interactions separately from injected chooser fixtures.

The complete R01–R09 / T01–T18 finish line remains active. Current repository tests
do not prove selected-file OS permissions, hostile filesystem race resistance,
physical input/VoiceOver, power-loss durability or macOS 14 runtime compatibility.
Deletion removes managed records; it is not secure erasure of SQLite/WAL, filesystem
backups or previously exported copies.
Explicit reference removal still scans persisted message/draft payloads; current
reference validation rehashes up to 25 MiB of content. Those latency costs remain
unmeasured. Export capture/JSON encoding and reference scans are not hard peak-memory
or native 10k-message performance proofs; see [export limits](WORKSPACE-EXPORT.md).

## Verification checkpoint

The combined suite contains **395 tests** (225 core + 170 native). Attachment-specific
coverage includes 13 content/repository tests, 5 historical migration/recovery tests,
7 coordinator no-transmission tests and 5 native compatibility tests. Fixtures use
temporary stores and synthetic content, including exact 10 MiB reopen and an impossible
base64 export lower bound; they never read a user-selected or credential file.
An injected save failure verifies atomic draft/content replacement and pruning rollback
through reopen. Historical model bodies are compared unchanged against the previous
public version. Existing native smokes exercise text-only fixtures, not a completed
attachment chooser/transmission workflow.
