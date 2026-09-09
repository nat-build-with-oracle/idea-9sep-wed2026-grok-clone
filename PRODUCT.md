# Product

<!-- impeccable:product-schema 1 -->

## Platform
macOS desktop. The implementation uses SwiftUI/AppKit; Windows/Linux delivery is not committed. This supersedes the provisional browser-first approach.

## Stack
Current implementation: SwiftUI with narrowly scoped AppKit bridges and Core Data for a macOS-first app. Tauri 2 remains an unselected alternative if Windows/Linux becomes a requirement; the source release does not imply cross-platform support.

## Users
Nat and people managing several named AI teammates in a messaging-style workspace.

## Product Purpose
An independently implemented Grok Bot-style app based on the supplied screenshots and observed interaction flows. Let users create bots and groups, exchange messages, and manage recurring tasks.

## Capabilities and Constraints
- Persistent local workspace, bot profiles, group membership, messages, and routines.
- Optional configurable model backend. Never present canned replies as real AI execution.
- No use of proprietary app code, private Cursor endpoints, or credentials/account storage from the inspected reference app. Our provider credentials are separately and explicitly supplied by the user.
- Computer preview is a reference, not a live cloud computer. No unattended local command execution.
- Routines execute only while the app is running and the machine is awake. Relaunch/wake policy must be explicit. No claim of 24/7 execution without a separately supplied worker service.
- Model/provider and deployment preferences remain open; unconfigured functionality must be honest and usable.

## Brand Commitments
Honor the supplied dark, three-column macOS messaging reference. Use original implementation and geometric bot avatars. Identify the rewrite as independent in settings/help.

## Evidence on Hand
- A user-supplied screenshot was retained unchanged as a private design reference. It is excluded from the public repository and is not needed to build or test the app.
- Earlier conversation: sidebar, new-chat and group-picker screenshots and read-only installed-bundle findings.
- No existing product source or live-computer backend was provided. Provider credentials are optional, user-controlled inputs; they are not repository assets.
- The SwiftUI/AppKit shell has separate sample and durable modes. `scripts/native-app.sh` packages the durable app; `scripts/native-prototype.sh` retains the session-only visual fixture. `Packages/WorkspaceCore` provides Core Data persistence and streamed replies; native settings/chat, profiles, message replies, text-only export and confirmed bot deletion are wired and fixture-tested. Z.ai/9router templates and explicit session-only credentials are available. A user-authorized minimal native Codex reply passed; broad provider/9router validation and authorized Keychain/signing remain open. See `docs/DURABLE-WORKSPACE.md` for evidence and remaining features.

## Product Principles
- A conversation is the primary work surface.
- Keep data local by default and provide an export.
- Explain offline/unconfigured states rather than simulate successful external work.
- Native keyboard, accessibility, and window-resizing behavior are implementation quality requirements.
