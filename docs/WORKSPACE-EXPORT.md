# Workspace export v3

**Implemented scope:** File → Export Workspace… or Settings → Workspace export
creates a versioned JSON snapshot of the current persisted workspace. This is an
experimental source-build feature, not a restore tool or a database-file backup.

## Included and excluded

Included: all bots (including hidden ones), direct/group conversations and ordered
membership, **all** message pages, attribution and reply references, unsent drafts,
generation state/partial text, routine definitions/run history, public provider configuration,
and exact bytes/metadata for every referenced stored attachment, including draft files.
The snapshot captures one repository revision on its serialized Core Data queue;
streaming may continue afterward, so later deltas are not part of that revision.
Current composer drafts are flushed before capture. Detached, unsaved profile or
provider form edits, session appearance preferences and display name are not exported.

Provider fields are explicitly allowlisted: `id`, `name`, `kind`, `apiRoot`,
`modelID`, `allowsLoopbackHTTP`. **Credential references are omitted**, not merely
masked. Export has no credential-service or network dependency and does not read
Keychain. Credential-store API key values, imported login/refresh tokens and transport
auth headers are not exported; auth files are never copied.
User-entered text and endpoint paths are not secret-scrubbed: a secret pasted into a
message, prompt, name or selected attachment remains user content. The native UI warns to review before sharing.

Routine-run history includes immutable provider bindings and typed outcomes. Format 3
adds the [attachment storage foundation](ATTACHMENTS.md): exact content once per
referenced ID, with metadata/hash/reference validation. Missing or corrupt content
rejects capture rather than silently losing files. Native file selection/chips and
confirmed provider transmission, as well as import/restore, are still unimplemented;
this does not close all R04/R06/T11 acceptance requirements.

## Format contract

- `formatVersion: 3`, `sourceSchemaVersion: 3`, `revision`, `exportedAt`, `summary`.
- Arrays: `bots`, `conversations`, `messages`, `drafts`, `generations`, `routines`,
  `routineRuns`, `providers`, `attachments`. Counts in `summary` describe those arrays.
  `summary.attachmentBytes` is the total raw byte count, not base64/JSON size.
  Each attachment entry has `attachment` metadata and a `data` base64 string.
  Its SHA-256 covers the decoded raw bytes. No original or internal file path is included.
- UUID order is stable; messages sort by conversation UUID then ascending sequence.
  Group member order is preserved. JSON object keys are sorted.
- Dates are JSON numbers: **seconds since 2001-01-01 00:00:00 UTC**, Foundation's
  reference date, including fractional precision. They are **not Unix timestamps**.
  This matches the persisted DTO representation and round-trips with the default
  Swift `JSONDecoder`. A consumer needing Unix seconds adds `978307200`, accepting
  floating-point conversion rounding. No fractional timestamps are dropped for display.
- Re-encoding the same document is deterministic; separate captures have different
  `exportedAt` values and may have different revisions. This is not a standard
  canonical-JSON signature format, database-file backup, or supported import contract.
- Default encoded-file limit: **100 MiB**, rejected without truncation. Capture
  preflights attachment metadata against the base64 lower bound before loading
  payloads when they alone cannot fit. Otherwise capture materializes records/content
  and encoding allocates the JSON before checking its final size;
  this is an output limit, **not a hard peak-memory bound**. Encoding/file I/O run
  away from the main actor. Large-workspace performance remains unbenchmarked.

Format 1 did not contain run history; format 2 did not contain attachment content.
This release writes format 3. Consumers must check the format version rather than
assume their format-1/2 representation can preserve the new fields. No import/restore feature is implied.
See the [routine data contract](ROUTINES.md) for occurrence and provider-binding semantics.

## Native save and failure contract

The standard asynchronous `NSSavePanel` restricts the type to JSON and supplies the
explicit destination/overwrite interaction. Cancel causes no export-driven flush,
encoding or file write. The usual independent draft autosave is unaffected. See
[Apple's allowed types](https://developer.apple.com/documentation/appkit/nssavepanel/allowedcontenttypes)
and [sheet completion API](https://developer.apple.com/documentation/appkit/nssavepanel/beginsheetmodal(for:completionhandler:)).

The durable bundle retains App Sandbox and network-client permission, replacing
user-selected read-only with **user-selected read-write** for native import/export.
It does not request broad home-directory access or retain paths/bookmarks. Save Panel
grants access to the selected file; successful explicit security-scope starts are
balanced with stops. See [Apple's entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)
and [sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

One operation is claimed synchronously. Draft-save, snapshot, encode or write errors
cannot produce a success status. Stale workspace callbacks cannot start a write for
the new workspace. Once writing an accepted immutable snapshot has started, quitting
or reconnecting waits for it; a failure during the quit wait keeps the app open.
Pending file selection
is cancelled on quit. The app reports counts after successful write, not paths or raw
filesystem errors.

The writer rejects existing nonregular, symbolic-link and multiply linked targets,
then uses Foundation's atomic auxiliary-file/replacement operation. Existing regular
files may be replaced after the native confirmation. **Use a private trusted folder**:
path prechecks are not a descriptor-based defense against concurrent malicious changes
to a shared folder. This is not an fsync/crash-durability guarantee. Apple documents
both [atomic writing](https://developer.apple.com/documentation/foundation/nsdata/writingoptions)
and its [shared-directory caution](https://developer.apple.com/documentation/foundation/nsdata).

## Validation

```sh
scripts/native-app.sh test
scripts/native-app.sh export-smoke
scripts/native-app.sh export-smoke --small
```

Original text-only export milestone suite: **263 tests passed** (137 core + 126 native shell), including
5 core export tests and 23 native export tests.

Core tests cover full history beyond 100 messages, hidden bots, group order, drafts,
reply references, partial generations, routines/provider metadata, credential-reference
exclusion, exact round-trip encoding, size/dangling-reference rejection and concurrent revision
consistency. Native tests cover destination cancellation, single-flight/lifecycle guards,
draft-save/size/write failures, stale workspaces and actual temporary-file writes.

Core/native attachment tests extend this baseline with content persistence,
reference-safe deletion/export and preservation by native text editing. They do not
exercise the OS file picker. The separate [attachment smoke](ATTACHMENTS.md) covers injected selection and confirmed offline transmission.

The sandboxed native smoke uses synthetic data and an **injected destination inside
its own temporary directory**, real encoding/atomic replacement and a rendered Settings
window. It does not automate native Save Panel selection/overwrite, prove its external
sandbox grant, or test disk-full, hostile shared-folder races, power loss, VoiceOver or
macOS 14 runtime behavior. Signing remains local/ad-hoc; notarized distribution is open.

See [durable workspace evidence](DURABLE-WORKSPACE.md) and the full
[rewrite contract](NATIVE-REWRITE-CONTRACT.md) for remaining work.
