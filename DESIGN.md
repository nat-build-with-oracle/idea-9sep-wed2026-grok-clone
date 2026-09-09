# Design

## Source of truth
- Status: Active native design contract; browser implementation assumptions are superseded. See docs/NATIVE-REWRITE-CONTRACT.md.
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
- Default Dark preserves base #070707, sidebar #111111, agent bubble #262626, selected row #353535 and subtle text #ababab. Appearance settings add explicit Light and Follow System choices; this is not a replacement of the reference default.
- Light uses near-white #fafafa, sidebar #f1f2f4, bubble #e8e9eb, selected #d8dadf, composer #e7e8ea, foreground #1b1c1e, secondary #5c6066, separator #cdd0d5 and accessible blue #0068d9. Light warning text uses #924600 rather than a low-contrast bright orange. Use semantic tokens for decorative contrast, fields, selection and message surfaces rather than scattered fixed dark colors. Avatar brand colors/eyes remain original.
- System sans matching the reference, 15–16pt default; no downloaded fonts.
- Desktop sidebar 280pt (240–400pt), flexible chat minimum 424pt, inspector default 320pt/minimum 280pt.
- Rounded message bubbles and pill composer; 1px separators, light menu shadow only.
- Original vector bot shapes with paired tilted eyes; green, magenta, gray, violet, blue.
- Purposeful short menu transitions; reduced-motion override.
- User reference is kept unchanged locally for design/testing, excluded from public source and never shipped as live content. The computer panel uses an explicit disconnected state until an adapter is connected.

## Components
Avatar, icon button, conversation row, message bubble, timeline separator, composer, reply reference card, recipient picker, inspector, routine row, profile editor, sheet, settings section. Production ownership and test seams are defined in docs/NATIVE-REWRITE-CONTRACT.md. The shell under Prototypes/NativeShell supports a sample-only bundle and a durable bundle through Packages/WorkspaceCore. Source-directory naming is transitional; provider effects now run through an injected, fixture-tested coordinator; native routine editing/history and awake scheduling are connected with explicit destination/owner consent (docs/ROUTINES.md). Real-provider/signing and full native accessibility checks remain open.

## Accessibility
Semantic controls with names; keyboard submit and Escape; visible focus; dialog focus trapping/restoration; live status announcements; readable contrast; no keyboard-only hidden actions. Respect reduced motion.

## Responsive behavior
Three columns on wide desktop. Collapse inspector when sidebar + chat + inspector minimum widths cannot fit. Minimum supported window content size is proposed as 760×600pt. Pane widths and preferred visibility persist as local UI preferences, separate from workspace/export data. Widths are finite and clamped to documented ranges. Inspector auto-collapse does not overwrite the preference; the chat keeps its minimum by temporarily constraining wide saved sidebars. No horizontal chat scrolling except within code blocks; composer remains visible.

## Interaction states
Sidebar rows use persisted latest-message previews and dates, including unopened chats,
and a compact unread-reply count (visual cap 99+, exact count in accessibility text).
Only assistant messages count; sending a message or recording a retry event is not a new
reply. Read state advances only for the latest rendered transcript in the active, key
workspace window, at the bottom, without a picker or editing sheet. Active generations
delay acknowledgement so later deltas to the same message are not silently marked read.
Background chats and scrolled-back transcripts retain their unread state; hiding alone
never changes read state. Read
status persistence errors have a separate retry action, never an optimistic badge clear.

Loading, empty searches, empty groups, sending, profile validation/conflict, unsaved-profile discard, provider error/offline, routine paused/running/failed, upload validation, API failures, and persistence failures must be explicit. Profile edits use a detached buffer tied to a stable bot/group identity: navigation cannot redirect a save, stale editable fields require an explicit reload, and Cancel/Escape/window close confirms before discarding dirty fields. Reply cards use intrinsic content height, a two-line excerpt, an explicit cancel action in the composer, and loading/unavailable states. Parent selection is conversation-scoped and does not send; jump-to-original must not redirect later navigation. Public sample conversations are synthetic project-planning examples, not copied user history or live service output.

Appearance/layout settings use a detached edit buffer with Save/Cancel and a dirty-close warning; Save applies to the workspace, Settings and sheets without discarding provider forms, drafts or selections. AppKit may commit active marked text during an appearance transition; do not recreate composition based only on unchanged text. Physical IME/automatic-appearance integration remains a validation gate (docs/APPEARANCE.md). Dragged divider widths persist when adjusted. Follow System removes app/window overrides and follows the effective OS appearance. Tests/smokes inject isolated preference storage and never change the user's normal preferences.

## Content voice
Permanent bot deletion uses a dedicated confirmation sheet with affected-record counts,
group names/remaining memberships and explicit cancellation/no-undo disclosure. Keep action
buttons outside the scrolling impact list. No destructive Return default. Groups left with
0/1 members retain history/drafts and show a repair action instead of a sendable composer.
See [deletion contract](docs/BOT-DELETION.md).

Export uses File/Settings and the native JSON Save Panel, not a custom path field.
Disclose all saved/hidden content and secret-scrubbing limits before selection; separate
busy, success-count and sanitized failure states. No implicit upload or automatic path.
Unsaved profile/provider forms are not included. See [export contract](docs/WORKSPACE-EXPORT.md).

Short, clear, calm. Use Bot, group chat, computer, routine. No fabricated success claims.

## Implementation constraints
No third-party dependencies without explicit adoption. The app uses native SwiftUI/AppKit plus a Swift package core and Swift unit tests; XCUITest coverage remains open. No localhost HTTP server is needed. Never expose provider secrets in UI snapshots, logs, store exports, or fixtures.

## Open questions
- Desired model/backend: configurable text-only adapters exist, but broad live-provider compatibility remains unverified; no private Grok Bot API dependency.
