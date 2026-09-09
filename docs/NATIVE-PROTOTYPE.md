# Native feasibility prototype

This is a reversible SwiftUI/AppKit spike for step 2 of the [native rewrite contract](NATIVE-REWRITE-CONTRACT.md), not the finished app. It uses original native code and vector avatars; the reference PNG is not embedded in the executable. SwiftUI remains a recommendation for macOS-first, not a user-confirmed cross-platform decision.

**Scope note:** this page describes the sample-only `NativeShellPrototype.app`. The same native shell now also builds a separate durable `BotWorkspace.app`; see [durable workspace](DURABLE-WORKSPACE.md). The sample bundle still uses session-only fixtures and never silently copies them into the durable store.

## Run and reproduce

```sh
scripts/native-prototype.sh build       # local ad-hoc-signed sandboxed .app
scripts/native-prototype.sh run         # normal macOS launch
scripts/native-prototype.sh test        # model and composer-policy tests
scripts/native-prototype.sh snapshot    # native window-view render, then quit
scripts/native-prototype.sh snapshot --small
scripts/native-prototype.sh snapshot --picker
scripts/native-prototype.sh snapshot --group
```

The app is `Prototypes/NativeShell/.build/NativeShellPrototype.app`. Snapshot mode prints the PNG path in the prototype's sandbox temporary directory. It renders this app's view hierarchy, not the desktop or any other application. Screenshots and build output are ignored artifacts. Public sample content is synthetic; private reference names, account details and conversation history are not included.

## What the prototype contains

| Surface | Available now | Boundary |
|---|---|---|
| Workspace | Native window controls, dark three-pane layout, split handles, auto-collapsing inspector | Divider preferences are not saved; interactive resize quality remains a manual gate |
| Sidebar | Sample bots, search, conversation selection, hide/show-hidden | Session-only; sample history is not current data |
| New chat | Search existing bots; create bot; select 2–6 bots and create group | Original independent local IDs; no model or cloud work |
| Transcript | Selectable native text, timestamps, default latest-message position | Small fixture only; no paginated persistence or performance claim |
| Composer | AppKit text editor, local user messages, per-conversation drafts | Return policy is tested, live IME routing is not; changes disappear on quit |
| Inspector | Explicit disconnected computer; paused preview routine list | No screen capture, remote-control adapter or scheduler |
| Panels | Bot creation, template catalog, profile, settings, add paused routine | Settings is a prototype sheet, not the contracted separate production scene |

Local send is deliberately a **preview action**, not the production provider-unconfigured behavior. Its notice states that no provider is connected and the session is not saved. Adding a routine does not schedule anything. Attachments expose an availability explanation rather than reading files. Template entries create separate local bots, not downloaded integrations.

## Layout and flow

```text
+-------------------+---------------------------+----------------------+
| native controls + | Bot / group       details | Settings / collapse  |
| Search            |---------------------------|----------------------|
| Bot conversations | Selectable transcript     | Computer disconnected|
|                   |                           | Paused routines      |
| Marketplace       |                           |                      |
| Profile           | +  Native composer  Send  |                      |
+-------------------+---------------------------+----------------------+
          Cmd+N -> recipient picker -> existing bot -> conversation
                                  -> create bot   -> conversation
                                  -> select 2–6   -> group conversation
```

At 800×650pt the inspector is absent and the composer remains visible; at 1280×880pt all three panes render. This is screenshot inspection, not an exhaustive resize test.

## Verification record — 2026-09-09

Host: macOS 26.5.1, Apple Silicon, Xcode 26.6, Swift 6.3.3. Deployment target is macOS 14; that OS has **not** been runtime-tested.

- The original **25 model/input-policy tests** remain passing, with one additional synthetic-fixture regression test. Five AppKit tests cover plain-text/undo/accessibility configuration, marked-text preservation across SwiftUI updates, selector refusal without a key event, composer replacement/teardown, and disabled-editor behavior. They do not simulate or claim a live IME session. Six durable UI-adapter tests bring the shell suite to **37 passing tests**.
- Native `.app` was launched normally through Launch Services and in snapshot mode, producing chat, narrow-chat, recipient and group renders. An initial latest-message clipping defect was found visually and corrected with the native default bottom scroll anchor; desktop and narrow confirmation renders show the final bubble above the composer.
- Local code-signature verification passes. Extracted entitlement is only `com.apple.security.app-sandbox=true`; no network/file-access privilege was added. This is ad-hoc development signing, **not** Developer ID, notarization, or distribution readiness.
- Source scan finds no HTTP URLs, URLSession calls, WKWebView, or subprocess invocation in prototype Swift sources. This is static evidence, not network packet capture.
- Swift formatting lint, shell syntax check and whitespace validation are part of the verification commands below.

```sh
swift test --package-path Prototypes/NativeShell
xcrun swift-format lint --strict --recursive Prototypes/NativeShell/Sources Prototypes/NativeShell/Tests
bash -n scripts/native-prototype.sh
codesign --verify --strict Prototypes/NativeShell/.build/NativeShellPrototype.app
git diff --check
```

### Still open — do not mark these passed

- Real keyboard event routing: IME candidate acceptance, Shift+Return, shortcuts, picker arrows, focus restoration, undo, text selection and VoiceOver. Pure input-policy tests are not end-to-end IME evidence.
- Full accessibility tree audit, interactive pane dragging, large text and reduced-motion checks.
- T13: 10,000 **persisted** messages, paginated initial 100, 50 updates/sec and Instruments timing. Small fixture rendering proves none of those thresholds.
- Historical schema migrations, file attachment/export boundaries, native provider/Keychain integration, routine execution and remaining lifecycle recovery. Persistence and provider core now have separate implementation evidence in [durable workspace](DURABLE-WORKSPACE.md) and [provider core](PROVIDER-CORE.md); those are not full UI/release completion.
- Remaining production bot/group edits and lifecycle semantics; separate settings window; macOS 14 execution; release signing/notarization.

Full R01–R09 / T01–T18 acceptance remains governed by the production contract. This milestone neither completes the full rewrite nor replaces the remaining work with a mock UI.
