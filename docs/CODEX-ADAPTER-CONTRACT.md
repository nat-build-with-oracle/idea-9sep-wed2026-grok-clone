# Experimental Codex login adapter — implementation contract

Status: **implemented experimentally; release/product gates remain open** · 2026-09-10

The requested outcome is ChatGPT-backed replies using an explicitly supplied
existing Codex login, without a local command executor and without treating an
OAuth token as an OpenAI Platform API key. This adds to—not replaces—the native
rewrite's full product contract.

## Decision boundary

Codex App Server is the documented integration surface for managed login and
thread/turn lifecycle. The inspected protocol does not establish one universal,
fail-closed switch disabling all built-in tools, MCP and plugins. Do not equate
`approvalPolicy: never` with no execution.
[Official App Server documentation](https://learn.chatgpt.com/docs/app-server).

An alternative fixed-origin, text-only HTTP/SSE client is technically feasible.
Codex's public source identifies the backend base and Responses request shape:
[provider base](https://github.com/openai/codex/blob/b631d9217025b9960510808443125da3fffc7857/codex-rs/model-provider-info/src/lib.rs),
[request type](https://github.com/openai/codex/blob/b631d9217025b9960510808443125da3fffc7857/codex-rs/codex-api/src/common.rs).
These are implementation details, **not a public third-party API stability or
account-entitlement guarantee**. The UI must label the adapter experimental;
failures must not trigger silent endpoint, account, or transport substitutions.

Do not import a real token into 9router merely to achieve this goal: the reviewed
router import persists token material in its database without an encryption layer,
does not itself prove authentication, and can split rotating-refresh ownership.
Normal 9router chat remains a separate adapter using only its router client key.

## Required invariants

1. **Explicit ingress.** An explicit user-selected Codex auth JSON (or a deliberate
   local stdin handoff) supplies only `tokens.access_token` and
   `tokens.account_id` in ChatGPT auth mode. Limit the input size and reject malformed
   or other-auth-mode files. Never display token values, scan the whole home folder,
   load credentials on startup, or treat file contents as instructions.
2. **Memory-only lifetime.** Keep the extracted material in the explicit session
   credential route. No copied auth file, OAuth Keychain item, raw auth JSON in
   domain records, token-bearing diagnostics or secret-bearing snapshots. A restart
   requires re-import. The original file is never modified.
3. **One refresh owner.** Never use/copy the refresh token, call OAuth refresh,
   log out the Codex session, or overwrite its cache. An expired/rejected token asks
   for an updated explicit handoff after the user signs in through Codex.
4. **Fixed destination.** Only
   `https://chatgpt.com/backend-api/codex/responses`, normal TLS verification,
   no endpoint override, redirects, cookies or proxy-header credential forwarding.
   Use the app's own client identity, not a claim to be an official Codex binary.
5. **Text-only wire contract.** Explicit `tools: []`, `tool_choice: "none"`,
   `parallel_tool_calls: false`, `store: false`, `stream: true`; construct input
   from supported text roles. No hosted tools, MCP, shell, computer or file actions.
   Reject tool/function output rather than interpreting it. `store: false` is not
   a blanket promise about the provider's retention policies.
6. **Native integration.** A distinct provider kind selects this adapter. Existing
   v1 provider records decode to chat-completions by default. Arbitrary compatible
   endpoints must never receive Codex credentials: use a Codex-only session-reference
   namespace and reject those references in the generic adapter, including after
   metadata edits. Settings shows the fixed host,
   experimental status, selected model, memory-only lifetime and context scope.
7. **Generation semantics stay intact.** Validate before consuming a draft,
   persist-before-send, bounded SSE/timeout/output handling, immutable attribution,
   cancellation, manual retry and restart interruption remain in force. Socket
   cancellation is not a promise that upstream work/billing is undone.

```text
Explicit auth-file selection → bounded parser → access token + account ID (memory)
  → Codex-only session reference → provider kind validation → fixed-origin text/SSE
  → existing generation persistence / attribution / Stop / Retry

Refresh token / raw auth file ─X→ workspace, Keychain, router DB, logs, exports
Codex credential reference  ─X→ custom chat-completions endpoint
```

## Implementation and verification gates

- Fixture-only credential parser tests: valid ChatGPT file, wrong mode, missing
  fields, oversized input, control characters, and no refresh-token retention.
- Provider-kind backwards decoding and strict fixed-destination validation tests.
- Request assertions for own client identity, account header, tools disabled,
  correct text input and absence of credentials in the body.
- Codex Responses SSE tests at arbitrary UTF-8 boundaries; completion, failed /
  incomplete / malformed / early-end cases; unsupported tool output fails closed.
- Reuse the existing HTTP/SSE transport boundary where safe; existing transport
  regressions must pass before and after any extraction. No new dependencies.
- Native import/save/session-expiry/draft-preservation tests and an isolated native
  end-to-end reply test; fixtures stay synthetic and offline in the normal suite.
- A user-authorized manual fixed-origin probe can establish feasibility for one
  account at one time. It does not prove native integration or broad compatibility.
- Keep local account diagnostics private; commit/push only original source,
  synthetic tests and non-secret contracts. Release signing, all other R/T gates
  and remaining product features stay open until individually verified.

## Implemented boundaries and current evidence

- `ProviderConfig.kind` defaults legacy JSON to chat-completions. Codex metadata
  requires its fixed root and `session-codex-` reference; generic adapters reject
  that namespace even if kind/root metadata is changed. The protected Keychain
  implementation also rejects direct Codex-reference writes.
- `CodexSessionCredential` is non-Codable and redacts descriptions. Its versioned
  memory-only envelope contains just access/account fields, never source JSON or
  refresh/ID tokens. Session-store recreation loses imported access.
- Native Settings has an explicit bounded user-selected file import, a stale-import
  generation guard, fixed destination, editable model, kind-change credential
  re-entry and memory-only/context disclosures. The durable bundle adds only
  user-selected **read-only** file access, not broad filesystem access.
- The fixed backend was observed returning HTTP 200 without Content-Type. Only the
  Codex adapter accepts an absent header and then requires strict SSE/event parsing;
  explicit non-SSE MIME types and generic missing-MIME responses are still rejected.
  JSON/HTML bodies fail closed. URL, redirect, TLS, byte and time limits are unchanged.
- Codex SSE framing caps line/event sizes at 1 MiB, total wire at 16 MiB and emitted
  text at 4 MiB. Success requires explicit completed status, response ID and supported
  output items and emitted text. The terminal output array can omit repeated messages
  only after a validated nonempty assistant `output_item.done`; a bare delta,
  added-only item or empty completion is insufficient. Reasoning is not rendered as assistant text; tool/unknown output,
  malformed payloads and premature EOF fail. Refusal completion uses the `refusal`
  field from the [official Responses streaming schema](https://platform.openai.com/docs/api-reference/responses-streaming/response/refusal).

Reproducible offline native evidence:

```sh
scripts/native-app.sh test
scripts/native-app.sh codex-smoke
scripts/native-app.sh codex-smoke --settings
```

`codex-smoke` uses synthetic auth plus an intercepted byte-split HTTP/SSE response,
then the real provider router, coordinator, repository and native presentation path.
It verifies completed attribution and draft clearing without sending a real request.
The explicit `codex-smoke-stdin` diagnostic is **not** part of normal tests: it accepts
a deliberate auth-file handoff and makes a real minimal request in an isolated store.
It does not refresh, read a hardcoded home path, or copy the original credential file.

This slice does not close the full R01–R09/T01–T18 product contract, release signing,
macOS 14 runtime, complete accessibility, routine execution or real 9router gates.

Manual native checkpoint (2026-09-10): an explicitly authorized stdin handoff
completed the expected minimal text reply through the built native app, provider
router, real SSE transport, coordinator and isolated SQLite persistence. Attribution
and draft clearing passed; the original auth file remained unchanged and no refresh
was attempted. Diagnostic account information is private. This does not prove a
public API guarantee, all accounts/models, native file-picker automation or release
signing. Normal reproduction remains fixture-only unless a developer explicitly
chooses the separately named live command.
