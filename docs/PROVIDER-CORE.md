# Provider core — experimental library checkpoint

The Swift package now contains a model transport and durable generation coordinator.
**The native app does not call them yet.** Provider settings, Keychain UI, outgoing
network entitlement and end-to-end native streaming remain open. The app's Send
action preserves a local draft rather than fabricating a reply.

## Implemented in `Packages/WorkspaceCore`

- `ChatProvider.swift`: provider protocol, request/event DTOs, endpoint validation,
  controlled error messages and bounded incremental UTF-8/SSE parsing.
- `ChatCompletionsProvider.swift`: ephemeral URLSession POST transport, SSE-only
  successful responses, redirect refusal, cancellation and timeout mechanisms.
- `CredentialStore.swift`: protocol and exact-reference Keychain actor. Secrets
  are runtime `Data`, not provider metadata or Codable workspace fields. No
  plaintext fallback is provided.
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

The core suite has **62 tests**: 29 repository, 10 generation/coordinator,
15 SSE parser and 8 transport/request tests. Transport tests use URLProtocol;
coordinator tests use fake providers and credentials with temporary SQLite stores.
No live requests, billable calls, real credentials or existing Keychain records
were used. Transport tests also passed ten consecutive runs during development.

Coverage includes Unicode at every byte split, CR/LF/CRLF, BOM/comments, terminal
events, malformed/early-ended streams, size limits, unsafe URLs, request encoding,
HTTP failures, content types, redirect refusal, cancellation, queue limits,
save-failure/no-transmission and shutdown behavior.

Not verified: live TLS/proxy/provider behavior; wall-clock timeout behavior;
real Keychain access and signing entitlements (including local ad-hoc signing);
native UI integration; and a sentinel-secret end-to-end store/export/log audit.
Do not call these release gates passed. Keychain errors must remain actionable
without weakening storage protections.

Context is limited to up to 100 prior messages and is captured when work is
enqueued; a queued request therefore does not acquire replies completed later.
Deltas currently persist individually, without write coalescing. The contract's
10k-message/50-updates-per-second performance budget is unverified. HTTP failures
are not automatically retried. Cancelling cannot undo a request already received
by a provider.
