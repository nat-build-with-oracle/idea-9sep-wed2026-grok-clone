# Computer and terminal surfaces — current boundary and proposed contract

**Status (2026-09-10):** the native app displays **No computer connected**. No
`WKWebView`, terminal protocol client, VNC/SPICE renderer, shell executor, or remote
computer adapter is wired into the inspector. This document records the requested
future surface without presenting it as shipped functionality or deployment authority.

## C01 — current inspector computer card (implemented)

```text
+--------------------------+
|      desktop icon        |
| No computer connected    |
| No live computer service |
| is configured ...        |
+--------------------------+
        Bot's screen
Routines                 +
```

- Entry: select a conversation and show inspector at a width that permits it.
- Behavior: static disconnected explanation; no connection, keyboard forwarding, screen
  capture, frame update, account reuse, or click-to-expand desktop operation.
- Evidence: `WorkspaceView.swift:963-978`; W-screen catalog; wide native fixture images.
- The name under the card is a UI label, not proof a computer is allocated to that Bot.

## C02 — deployment information is outside the public contract

```text
Public app documentation                 Private infrastructure
+----------------------------+           +----------------------------+
| Disconnected UI            |           | Not bundled or published   |
| Proposed permission gates  |    X      | No automatic connection    |
| Synthetic fixture evidence |           | No configuration transfer  |
+----------------------------+           +----------------------------+
```

This public documentation contains no private terminal service configuration,
network topology, addresses, routes, ports, credentials, or deployment history.
A disconnected app card does not establish an available remote session. Any future
connection needs its own explicitly approved configuration and live verification;
private operational findings are not part of this site's contents.

## C03 — proposed native terminal inspector and expansion

```text
INSPECTOR                         EXPANDED TERMINAL
+-------------------------+      +------------------------------------------+
| Terminal · chosen host  |      | Terminal · host / guest   [Disconnect] × |
| [Connect]               | ---> | Mode: View / explicitly enabled control  |
| No implicit connection  |      |------------------------------------------|
+-------------------------+      | terminal cells, cursor, scrollback       |
       select / expand          | status: connecting / live / closed/error |
                                +------------------------------------------+
```

This ASCII is a **proposal**, not a screenshot of existing source.

### Entry and lifecycle requirements

- Explicitly identify the destination and connection type before connecting.
  Do not derive a destination from arbitrary bot text or automatically reuse another app's auth.
- Connect only through the user-configured/approved service. No automatic public listener,
  installation, credential generation, remote restart, or provisioning is implied.
- State machine: disconnected → connecting → connected → disconnected, with explicit
  failed/auth-required/network-unavailable states. A terminal prompt is separate from a
  successful WebSocket upgrade. A blank frame must not be labeled a usable shell.
- One bound session owns its destination and Bot context. Switching Bots cannot silently
  send subsequent keystrokes to a prior guest or create extra remote sessions per thumbnail.
- Expanding/collapsing should reuse the intended session; define visibility/idle disconnect,
  app sleep/quit handling and cleanup before implementation. No hidden reconnect storm.

### Input, rendering and permission requirements

- Preserve terminal escape sequences, Unicode, cursor moves, colors, scrollback, resize
  and paste semantics through a real terminal renderer; raw text concatenation is not enough.
- Choose and review the renderer explicitly; this document adopts no dependency. A native
  shell with a WebView terminal would not make the whole app a Tauri/browser rewrite.
- Distinguish observation from writable interaction. Explain that a writable terminal can
  mutate the remote system. Do not call JavaScript key suppression a security boundary; establish
  any required read-only enforcement on the actual service side.
- No model-driven typing, clipboard collection, file transfer, credential insertion or
  autonomous command execution merely because a human opened the terminal.
- Prevent credentials/query tokens from entering screenshots, logs, history or workspace
  export. Record connection metadata separately only after defining its persistence policy.
- Keyboard capture begins only in the terminal's focused, explicitly enabled control mode;
  Escape and Disconnect remain reachable. Switching focus must not send app shortcuts remotely.

### Acceptance evidence before labeling it implemented

| Gate | Required proof |
|---|---|
| C-T01 | Chosen private route is reachable; WebSocket upgrade verified, not only HTTP 200 |
| C-T02 | Actual guest prompt/output rendered with destination attribution |
| C-T03 | Resize, Unicode, cursor/color and scrollback correct in inspector/expanded view |
| C-T04 | Explicitly authorized input goes to the named guest; disabled control truly cannot write under the chosen threat model |
| C-T05 | Bot switch, collapse, disconnect, network drop, sleep and quit terminate/reuse sessions as specified |
| C-T06 | No unintended shell input, secret logging, public exposure or user-workspace mutation in fixtures |
| C-T07 | Keyboard focus, accessible status, copy/paste disclosure and minimum-size layout verified |

## C04 — graphical desktop (reference / future, separate from terminal)

```text
Remote computer with a desktop session
  → separately reviewed graphical display transport
  → authenticated private connection + actual display renderer
  → inspector thumbnail → connecting overlay → expanded framebuffer
```

The reference images demonstrate this visual idea, not an available desktop adapter
for the rewrite. Provisioning or modifying a remote computer requires a separate,
explicit infrastructure decision. Terminal output and graphical desktop frames are
different kinds of data; neither is currently connected to this app.
The reference's **Teach a task** affordance additionally implies an automation/recording
contract that is not specified, implemented, or authorized here.

## Sources and related contracts

- [Reference layouts and observations](REFERENCE-SCREENS.md)
- [Current native feature atlas](FEATURE-ATLAS.md)
- [Native rewrite permission boundary](NATIVE-REWRITE-CONTRACT.md#6-endpoint-and-permission-contract)
