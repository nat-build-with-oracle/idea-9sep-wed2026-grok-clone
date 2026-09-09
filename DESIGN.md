# Design

## Source of truth
- Status: Native planning draft; browser implementation assumptions are superseded. See docs/NATIVE-REWRITE-CONTRACT.md.
- Last refreshed: 2026-09-10.
- Surface: main workspace, new chat/group picker, bot/group profile editor, inspector, settings and marketplace overlays.
- Evidence: user-supplied private reference screenshots, excluded from the public repository. The layout contract below is sufficient to build and test without those images.

## Brand
Quiet, precise messaging app. Near-black surfaces, subtle separators, bright original bot avatars. No marketing dashboard, artificial metrics, or claims of live computer access.

## Product goals
Build an independently runnable rewrite with persistent core workflows. Cloud-computer execution and private Grok Bot APIs are not supplied integration contracts.

## Personas and jobs
Manage named teammates; switch conversations; create a group; send messages; inspect recurring tasks; configure a model.

## Information architecture
Persistent sidebar → chat → optional inspector. New chat replaces the conversation. Use native settings windows and focused sheets/popovers for editing. Narrow desktop windows collapse the inspector before squeezing the composer. Mobile UI is not a v1 requirement.

## Design principles
Reference fidelity over decorative invention. Keep one primary focus per view. Show offline/provider states honestly without overwhelming the chat. Use predictable keyboard controls and preserve drafts.

## Visual language
- Base #070707; sidebar #111111; agent bubble #262626; selected row #353535; subtle text #aaa.
- System sans matching the reference, 15–16pt default; no downloaded fonts.
- Desktop sidebar 280pt (240–400pt), flexible chat minimum 424pt, inspector default 320pt/minimum 280pt.
- Rounded message bubbles and pill composer; 1px separators, light menu shadow only.
- Original vector bot shapes with paired tilted eyes; green, magenta, gray, violet, blue.
- Purposeful short menu transitions; reduced-motion override.
- User reference is kept unchanged locally for design/testing, excluded from public source and never shipped as live content. The computer panel uses an explicit disconnected state until an adapter is connected.

## Components
Avatar, icon button, conversation row, message bubble, timeline separator, composer, recipient picker, inspector, routine row, profile editor, sheet, settings section. Production ownership and test seams are defined in docs/NATIVE-REWRITE-CONTRACT.md. The shell under Prototypes/NativeShell supports a sample-only bundle and a durable bundle through Packages/WorkspaceCore. Source-directory naming is transitional; provider effects now run through an injected, fixture-tested coordinator; real-provider/signing checks and scheduler execution remain open.

## Accessibility
Semantic controls with names; keyboard submit and Escape; visible focus; dialog focus trapping/restoration; live status announcements; readable contrast; no keyboard-only hidden actions. Respect reduced motion.

## Responsive behavior
Three columns on wide desktop. Collapse inspector when sidebar + chat + inspector minimum widths cannot fit. Minimum supported window content size is proposed as 760×600pt. No horizontal chat scrolling except within code blocks; composer remains visible.

## Interaction states
Loading, empty searches, empty groups, sending, profile validation/conflict, unsaved-profile discard, provider error/offline, routine paused/running/failed, upload validation, API failures, and persistence failures must be explicit. Profile edits use a detached buffer tied to a stable bot/group identity: navigation cannot redirect a save, stale editable fields require an explicit reload, and Cancel/Escape/window close confirms before discarding dirty fields. Public sample conversations are synthetic project-planning examples, not copied user history or live service output.

## Content voice
Short, clear, calm. Use Bot, group chat, computer, routine. No fabricated success claims.

## Implementation constraints
No third-party dependencies without explicit adoption. The app uses native SwiftUI/AppKit plus a Swift package core and Swift unit tests; XCUITest coverage remains open. No localhost HTTP server is needed. Never expose provider secrets in UI snapshots, logs, store exports, or fixtures.

## Open questions
- Desired model/backend: configurable text-only adapters exist, but broad live-provider compatibility remains unverified; no private Grok Bot API dependency.
