# Superseded browser-first sketch

**Historical browser-first sketch, superseded by the native SwiftUI/Tauri planning request.** The browser implementation never began and its executable placeholder was removed. Native implementation has since progressed; see [durable workspace](DURABLE-WORKSPACE.md). The supplied image remains a private local reference, excluded from the public source.

Current contract and execution lanes: [Native rewrite contract](NATIVE-REWRITE-CONTRACT.md). The original sketch below is preserved as history, not a current acceptance gate.

The user asked for a new app based on the provided image, following the UI/function research. This is an original local implementation, not extraction or reuse of bundled proprietary code.

## Execution slices
1. Backend: persistence, API validation, bots/groups/messages/routines, optional provider, tests.
2. UI: screenshot-led shell, responsive navigation, chat and picker, original avatar/icon primitives.
3. Panels: bot/group/routine/profile/settings forms and local template marketplace.
4. Integration: real browser tests, model mock tests, keyboard and responsive checks, documentation.

## Acceptance
- Run with one local command and no dependency installation.
- Screenshot-led three-column interface and accurate dark palette, matching content hierarchy.
- Create/edit bots and groups, switch/search chats, preserve drafts and data across refresh/restart.
- Send and retain messages. Configured provider uses a real request; unconfigured/errors are explicit.
- Create/edit/pause/run/delete routines; scheduler runs only with server alive.
- Attach supported files, export workspace, edit profile and theme, install local bot templates.
- Mobile navigation and inspector remain usable; dialogs and picker keyboard-accessible.
- Reference image included unchanged; computer panel never claims live remote execution.
- API/unit checks and desktop/mobile browser validation recorded before completion.

## Verification record
Pending implementation.
