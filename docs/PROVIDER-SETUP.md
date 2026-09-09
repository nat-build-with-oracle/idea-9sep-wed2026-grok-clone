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
Model discovery in Settings and a live 9router end-to-end test remain unimplemented.

## ChatGPT login is not an OpenAI Platform key

The OpenAI Platform template requires a Platform API key and an available model.
Existing Codex ChatGPT login (`auth.json` or OS credential storage) is a different
authentication flow. Do not paste those tokens into the provider credential field.
[Official Codex authentication](https://learn.chatgpt.com/docs/auth).

The intended separate integration is Codex App Server, letting Codex own login and
refresh, using `account/read` for account state and thread/turn APIs for requests.
This is **not implemented** yet. The protocol inspected does not provide a single
enforced tool-free turn switch. `approvalPolicy: never` and a read-only sandbox are
not equivalent to disabling all tools, MCP servers, plugins and commands.
Adding Codex-backed chat requires an enforced, version-checked restricted server
boundary before enabling it in this non-executing chat app.
[Official App Server documentation](https://learn.chatgpt.com/docs/app-server).

Neither the app nor tests scan `pass`, read `auth.json`, import credentials from
other apps, or publish local account diagnostics. Keep keys out of command arguments,
screenshots, logs, repository fixtures and source control.
