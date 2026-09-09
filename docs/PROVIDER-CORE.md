# Provider integration — experimental native checkpoint

The Swift package's transport and generation coordinator are now wired to the
native app. Settings opens a separate native window; the composer exposes provider,
destination/model and an explicit single-bot target for groups. Streamed text is
persisted and attributed, and generation rows expose Stop/Retry. The normal suite verifies these paths with
**offline fixtures**; the separate experimental Codex adapter also has explicit
user-directed auth-file ingress. Without a configuration or
usable credential, Send preserves the draft and does not fabricate a reply.

## Native settings, credentials and data flow

- `ProviderSettingsView.swift`: secure replacement-only credential input, endpoint
  and model fields, explicit loopback-HTTP opt-in, content/destination disclosure,
  and dirty-state discard confirmation. Saved credentials are never loaded into
  the field. Setup templates and explicit credential lifetime selection are described
  in [provider setup](PROVIDER-SETUP.md). Saving does not claim a verified connection.
- `ProviderWorkspace.swift`: validates before credential access; writes a new
  credential reference before committing metadata; removes the newly written item
  if the metadata save fails. Key rotation leaves the old reference valid until
  the metadata commit succeeds. A changed API root or storage mode requires key re-entry.
- A blank replacement field retains the existing reference for the same API root and storage mode.
  Unused old-item cleanup failure is surfaced without undoing saved metadata.
- The composer shows the destination and context scope. Group replies use only
  the explicitly selected bot; mention-driven multi-bot rounds remain open.
  Provider/target choices are session selections, not yet per-bot persisted preferences.
- Draft flushes share one writer. A newer edit arriving during credential lookup
  is retained; sent content is cleared only when its local draft version still
  matches. Quit waits for saves and shuts down queued/active generations before
  closing the store. If cancellation cannot be saved, active transports still stop; the Retry saving action can persist cancellation and restore sending without replaying the queue.

## Signing boundary — do not skip

The default credential choice uses the data-protection Keychain. Apple documents that its
access groups derive from signing entitlements authorized by a provisioning
profile; an ad-hoc bundle must not invent a Team ID or assume this access works.
See [Apple TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains).

This app maps `errSecMissingEntitlement` (`-34018`) to an actionable signing
message and never silently falls back to plaintext or the legacy file Keychain.
An explicit **This session only** choice routes session-prefixed references to
process memory, never to Keychain. It does not bypass or fabricate Keychain access.
Recreating the credential service (including app relaunch) loses these keys.
Real authorized signing/profile setup and a Keychain roundtrip remain release
gates. [Apple's entitlement diagnostic](https://developer.apple.com/documentation/security/errsecmissingentitlement)
explains inspecting the built executable's entitlements.

The durable app requests App Sandbox, **outgoing network client**, and
**user-selected read-only files** for explicit Codex auth import;
the sample-only bundle still has only App Sandbox. No incoming server, broad file
access, or unprovisioned Keychain access-group entitlement is added. Credential
entry is explicit; no real key or existing Keychain record is used by normal tests
or offline smokes. The separately named `codex-smoke-stdin` is a deliberate live
diagnostic, not an automated test.

## Implemented in `Packages/WorkspaceCore`

- `ChatProvider.swift`: provider protocol, request/event DTOs, endpoint validation,
  controlled error messages and bounded incremental UTF-8/SSE parsing.
- `ChatCompletionsProvider.swift`: ephemeral URLSession POST transport, SSE-only
  successful responses, redirect refusal, cancellation and timeout mechanisms.
- `CredentialStore.swift`: protocol and exact-reference Keychain actor. Secrets
  are runtime `Data`, not provider metadata or Codable workspace fields. No
  plaintext fallback is provided.
- `SessionAwareCredentialStore.swift`: explicit reference-scoped memory/Keychain
  routing, preserving legacy provider references. No automatic fallback on failure.
- `ProviderPreset.swift`: setup suggestions for general Z.ai, local 9router,
  OpenAI Platform and custom endpoints; no entitlement or compatibility inference.
- `LocalRouterModelCatalog.swift` and native `ModelDiscoveryController.swift`:
  explicit credential-free loopback model discovery, bounded JSON, redirect refusal,
  cancellation and stale-result protection. A listed model is not a verified chat connection.
- `CodexSessionCredential.swift`, `CodexResponsesProvider.swift`, `CodexSSEParser.swift`:
  bounded explicit ChatGPT auth import, Codex-only session references, fixed-origin
  text requests with tools disabled, and fail-closed Responses SSE. `ProviderRouter`
  dispatches by kind; old provider JSON defaults to chat-completions. Native file
  import does not retain the source file or use refresh tokens. See the
  [Codex contract](CODEX-ADAPTER-CONTRACT.md) for compatibility and privacy limits.
- `GenerationCoordinator.swift`: persist the user message and queued generation
  before transport; one active request per conversation, at most three globally;
  cancellation, retry with a new attempt, and orderly shutdown.
- Repository events reject stale attempts and duplicate/out-of-order sequence
  numbers. Streamed assistant messages keep speaker identity/name snapshots.
  Cancellation preserves already-persisted text; retry preserves the original
  user message and previous partial output.

```text
Submit → validate provider/target + read credential + prepare context
       → commit user message + queued generation
         ├─ save fails → retain draft; do not call transport
         └─ save succeeds → queue → connecting → streaming → completed
                                            └────────────→ failed/cancelled
Retry → new attempt ID; original user message; earlier partial retained
```

The adapter implements a bounded text-only subset of the
[Chat Completions request format](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
and [streaming chunk format](https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events).
It is not a claim of compatibility with every provider. Tool calls, attachments
and other non-text output are not supported.

## Verification and limits

The core suite has **115 tests**: 29 repository, 11 generation/coordinator,
15 Chat Completions SSE, 15 transport/request, 8 provider-setup/credential-routing,
12 model-catalog, 9 Codex credential/request and 16 Codex SSE tests. Transport tests
use URLProtocol; coordinator tests use fake providers and credentials with
actual temporary SQLite stores. The shell has **70 tests**: 38 original tests,
16 provider-presentation, 7 model-discovery lifecycle and 9 Codex settings/flow tests.
Total: **185**. Codex additions cover explicit bounded import, unchanged source files,
no refresh/ID-token retention, backwards metadata decoding, fixed-origin/namespace
isolation, expiry/draft preservation, Stop/Retry attribution and credential rollback.

Normal automated tests/offline smokes make no live requests or billable calls and
use no real credentials or existing Keychain records. Manual diagnostics are
separate and account details are not published; a script-level HTTP probe alone
is not native-app success evidence. Transport tests also passed
ten consecutive runs during the earlier development checkpoint.

An explicitly authorized manual **native app** Codex check completed a minimal
text reply, persisted it with bot attribution and cleared the submitted draft in
an isolated workspace. The source auth file was unchanged and no token refresh
was attempted. Local account details stay private. This establishes one account/time,
not an official supported API, all models, the file-picker interaction, 9router or
Keychain/release-signing success.

Coverage includes Unicode at every byte split, CR/LF/CRLF, BOM/comments, terminal
events, malformed/early-ended streams, size limits, unsafe URLs, request encoding,
HTTP failures, content types, redirect refusal, cancellation, queue limits,
save-failure/no-transmission and shutdown behavior.

Not fully verified: broad live TLS/proxy/provider compatibility; all wall-clock
timeout modes (a first-event timeout now has a transport regression);
real Keychain access and signing entitlements (including local ad-hoc signing);
full keyboard/VoiceOver settings and streaming interaction; and a sentinel-secret
end-to-end store/export/log audit.
Do not call these release gates passed. Keychain errors must remain actionable
without weakening storage protections.

Timeouts currently measure first **user-visible text** (30 seconds), subsequent
visible-text idle time (60 seconds) and total request time (300 seconds). Reasoning
or lifecycle-only events do not extend those timers; long reasoning may time out.

Context is limited to up to 100 prior messages and is captured when work is
enqueued; a queued request therefore does not acquire replies completed later.
Deltas currently persist individually, without write coalescing. The contract's
10k-message/50-updates-per-second performance budget is unverified. HTTP failures
are not automatically retried. Cancelling cannot undo a request already received
by a provider.

## Reproduce native provider evidence without a key

```sh
scripts/native-app.sh test
scripts/native-app.sh provider-smoke
scripts/native-app.sh provider-smoke --small
scripts/native-app.sh provider-smoke --settings
scripts/native-app.sh provider-smoke --router-models
scripts/native-app.sh codex-smoke --settings
```

Provider smoke uses a new isolated temporary workspace, the explicit session credential route
and an explicitly injected fixture stream. It invokes the native presentation
service path, verifies one persisted user message and completed attributed reply,
checks the cleared draft, renders this app's window and removes its temporary
workspace. Settings capture uses a saved synthetic provider with an empty secret
field. It does not capture the desktop, connect to any endpoint or open the user's
normal workspace or its saved display-name preference. Smoke captures use an explicit synthetic profile name. Native renders are not a complete UI automation/a11y audit.
