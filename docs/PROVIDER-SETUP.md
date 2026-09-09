# Provider setup and authentication boundaries

Settings → New configuration → Setup template prefills editable connection fields.
It does **not** connect, read other applications' credentials, or verify account access.
Changing a template confirms before discarding edited fields, clears entered credentials
and resets loopback HTTP permission. Existing saved configurations remain manual/editable.

## Choose credential storage explicitly

- **Protected Keychain** (default): data-protection Keychain, requiring authorized
  signing. Storage failure remains an error; it never changes modes automatically.
- **This session only**: the app retains the key in process memory. Only an opaque
  reference and provider metadata are persisted. Quit/relaunch requires key re-entry;
  missing session keys keep drafts and never start a request. This makes an ad-hoc
  local build usable without claiming it has a production signing profile.

Changing the API root or storage mode requires re-entering the key. The app never
reads a stored key into the form or silently copies it between storage modes.
Swift memory is not a secure-zeroization guarantee; this option avoids deliberate
credential writes to disk, not OS swap, debugger or compromised-process access.
Chats and non-secret settings still persist normally in either mode.

## Z.ai general API

| Field | Value |
|---|---|
| Template | Z.ai general API |
| API root | `https://api.z.ai/api/paas/v4` |
| Suggested model | `glm-5.3`, editable; account availability is not assumed |
| Credential | Z.ai general API key |
| HTTP exception | Off |

The documented general API accepts chat-completions requests with bearer API-key
authentication. [Z.ai quick start](https://docs.z.ai/guides/overview/quick-start).

This standalone app does not use Coding Plan quota. That plan has separate endpoint
and supported-tool restrictions; do not treat subscription quota as general API
balance or switch endpoints to work around an account rejection.
[Z.ai Coding Plan FAQ](https://docs.z.ai/devpack/faq).

HTTP 429 can indicate account balance/quota as well as a transient rate limit.
Z.ai code `1113` specifically indicates insufficient balance or no resource package.
The app does not automatically retry failed requests or rotate accounts.
[Z.ai error codes](https://docs.z.ai/api-reference/api-code).

## User-managed 9router

| Field | Value |
|---|---|
| Template | 9router local gateway |
| API root | `http://127.0.0.1:20128/v1` for the documented local setup |
| Model | Exact ID from the router's `/v1/models` response/dashboard |
| Credential | The **router API key**, not the upstream key or ChatGPT OAuth token |
| HTTP exception | Explicitly check loopback HTTP for this local URL |

The app calls `POST /v1/chat/completions` through its existing text/SSE adapter.
9router's model convention is `providerAlias/modelId`, such as `cx/<model-id>`
or `glm/<model-id>`; use the exact available ID, not these placeholders.
The source reviewed exposes `GET /v1/models` and enables chat API-key validation
by default. Runtime/deployment settings can differ.
[9router upstream](https://github.com/decolua/9router),
[model route](https://github.com/decolua/9router/blob/699edac3/src/app/api/v1/models/route.js),
[chat handler](https://github.com/decolua/9router/blob/699edac3/src/sse/handlers/chat.js).

Start/configure the gateway separately; BotWorkspace does not install or launch it,
import its upstream account tokens, expose a local server, or claim upstream
subscription eligibility. The gateway receives your conversation content and can
forward it to its configured upstream. Locality does not make that forwarding private.
### Discover local models

After entering a loopback API root and explicitly enabling HTTP if needed, click
**Discover local models**. This sends only a credential-free `GET` to the root's
`/models` route. Filter the result and explicitly choose an ID; your typed model
is not replaced automatically. Prefixes, case and internal spaces are preserved.

Discovery refuses remote origins, redirects, non-JSON responses, malformed IDs and
oversized responses (1 MiB / 2,048 models). The filtered menu shows at most 80 IDs.
Changing the root, HTTP permission, template or configuration cancels/invalidates
the old lookup, as does closing Settings. Errors do not include raw server text.
No cookies, saved keys, credential-store reads or conversation content are involved.
An empty result is reported honestly, and a successful list is **not** validation
of the router key, upstream account, model permissions or a successful chat request.
Protected model-list deployments can use a manually entered model ID instead.

URLProtocol tests and a native fixture smoke cover this path. A real 9router
end-to-end chat test remains open:

```sh
scripts/native-app.sh provider-smoke --router-models
```

## ChatGPT login is not an OpenAI Platform key

The OpenAI Platform template requires a Platform API key and an available model.
Existing Codex ChatGPT login (`auth.json` or OS credential storage) is a different
authentication flow. Do not paste those tokens into the provider credential field.
[Official Codex authentication](https://learn.chatgpt.com/docs/auth).

### Experimental native Codex login

1. In Settings, choose **New configuration → Provider type → Codex login (experimental)**.
2. Give it a name and choose a model supported by your Codex account. The initial
   suggestion is `gpt-5.6-luna`; availability is not assumed or discovered automatically.
3. Click **Import Codex auth.json…** and explicitly select the file maintained by
   your Codex login. In the macOS file picker, Show Hidden Files is ⇧⌘. and Go to
   Folder is ⇧⌘G. No home-folder scan or startup credential import occurs.
4. **Save and use**, then send from the composer. Saving is not a connection test.

The importer accepts ChatGPT-mode JSON up to 1 MiB and retains only the access
token and optional account ID in process memory. It never copies the file, keeps
its pathname, uses its refresh/ID token, writes OAuth material to Keychain, or
changes Codex's login. Quit/relaunch or provider rejection requires explicit
re-import of a current file; Codex remains the only refresh owner. The API-key
field is never used for this login, and switching provider kind requires fresh,
kind-matching credentials rather than copying a stored value.

Requests go only to `https://chatgpt.com/backend-api/codex/responses`, with normal
TLS, no redirects, and this app's own client identity. Text input includes the
same disclosed conversation context as other providers. Tools are explicitly
empty/disabled; unknown or tool output fails closed. `store: false` is a request
setting, not a promise about the provider's retention policy. There is no shell,
MCP, browser, computer, file-action or tool interpreter in this adapter.

This is implementation-level compatibility with Codex's backend, **not a supported
public third-party API or subscription-entitlement guarantee**. Backend/model changes
can break it. There is no automatic fallback to another endpoint/account/transport.
[Adapter contract and source references](CODEX-ADAPTER-CONTRACT.md).

Codex App Server is the documented managed-login integration surface but is not
used here. The inspected protocol does not establish one universal tool-free turn
switch; `approvalPolicy: never` is not equivalent to disabling tools.
[Official App Server documentation](https://learn.chatgpt.com/docs/app-server).

Normal automated tests and `codex-smoke` use only synthetic credentials and an
intercepted URL load. An explicit `codex-smoke-stdin` developer command is separate:
it reads a deliberately supplied auth JSON from stdin, makes a minimal **real**
fixed-origin reply request, verifies native persistence/attribution in a temporary
workspace, and exits. It does not open the normal workspace, refresh the login,
or put secrets in arguments or files. Do not run it in CI or pipe credentials to
an unreviewed binary. It can consume account quota. Local account diagnostics stay
private; no `pass` scanning or credential lookup is performed by the app.

Keep keys and auth files out of screenshots, logs, repository fixtures and source
control. Swift process memory does not guarantee secure zeroization or protection
against OS swap, debuggers, crash dumps or a compromised process.
