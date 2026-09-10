# Screenshot catalog and visual evidence index

**Captured:** 2026-09-10, from source `ab2c2f3`; **24 scenarios passed**, producing **62 emitted snapshot records → 58 PNG files → 50 distinct SHA-256 raster contents**. Counts are not counts of independently implemented screens. Four appearance paths are emitted twice; several generic final-state names alias a specific already-captured state.

Open the [offline, searchable gallery](screenshots/index.html) locally, or use the image links below in Markdown. [Machine-readable manifest](screenshots/manifest.json). Return to the [feature atlas](FEATURE-ATLAS.md).

## What these images are

- Original SwiftUI/AppKit native-window **renders** from our sample/offline smoke app, not screenshots of Grok Bot, the real Mac desktop, or a provider account.
- The native renderer captures its own window view, including AppKit titlebar bounds. Manifest width/height are PNG pixels; a `--minimum` 760×600-point content request does not mean the PNG is exactly 760×600 pixels.
- All durable scenarios use temporary repositories and fake credentials/providers. Sample picker/chat scenarios intentionally use the non-durable sample bundle. The `unread` scenario explicitly injects foreground state.
- The fixed 24-scenario script never invokes live Codex stdin, a real model catalog, normal app data, or user reference images. It copies PNG bytes unchanged.
- Every file has dimension/hash verification. A separate visual review inspected 22 representative files; it did not inspect every variant or prove interaction. Its material limitations are recorded below, not hidden.
- No accessibility permission was granted/changed for this task. A read-only System Events check reported UI automation unavailable, so OS dialogs and missing interactive-only views were not fabricated or captured from the user workspace.

## Screen-to-evidence map

Every documented native screen/state has either an actual scenario or an explicit capture gap. Where W and M describe the same surface from different workflow angles, they share evidence rather than inflate screenshot counts.

| Screen IDs | Surface | Actual scenario(s) | Coverage / limitation |
|---|---|---|---|
| W01 | Desktop shell | workspace; sample-chat | Wide synthetic workspace, not private reference content; first-run/no-selection substate is source/ASCII-only, not captured. |
| W02 | Minimum shell | workspace-minimum; appearance-minimum | Actual 760×600 content request; inspector collapsed. |
| W03 | Sidebar/search/activity/hidden | unread; workspace | Unread before/after covered; search-result and hidden-menu-specific states not captured. |
| W04 | Direct conversation/actions | sample-chat; provider-chat | Sample direct transcript + durable group-provider response; message action popover not captured. |
| W05 | Ordered group recipients | group-round; group-round-minimum | Light/Dark composer and review. |
| W06 | Group mentions | mention; mention-minimum | Light/Dark composer, ambiguous/identity review, invalid mention recovery. |
| W07 / M01 | New chat picker | sample-picker | Sample-only recipient picker; shared native view, no durable creation interaction claim. |
| W08 / M02 | Group builder | sample-group-picker | Sample two-recipient selection, not full keyboard/transaction proof. |
| W09 | Reply workflow | reply | Available reply reference/composer; loading/unavailable/jump variants not captured. |
| W10 | Attachment chips/import | attachment | Post-fixture-send workspace and consent; no dedicated OS picker/progress/error capture. |
| W11 | Transmission review | attachment; group-round; mention | Distinct file/ordered-group/mention consent views; source determines exact trigger. |
| W12 | Generation lifecycle | provider-chat; codex-chat | Completed offline responses only; active/failed/cancelled/interrupted states lack dedicated renders. |
| W13 / C01 | Disconnected computer | workspace; sample-chat | Static disconnected inspector; never use reference desktops or external services as implemented evidence. |
| W14 | Marketplace/templates | none | No existing snapshot mode; ASCII + source contract only. |
| W15 | Local display profile | none | No dedicated render; ASCII + source contract only. |
| W16 / M04 | Edit Bot | edit-bot | Complete fixture editor with Cancel/Save. |
| W17 / M05 | Edit Group | edit-group | Fields/membership visible; capture cuts before footer. |
| W18 / M09 | Degraded group | deletion | degraded-group image exposes repair banner. |
| W19 | Global loading/storage failure | none | No deterministic renderer for these error overlays; documented state contract only. |
| M03 | Create Bot | none | Edit Bot is NOT a Create Bot capture; separate ASCII/source contract. |
| M06 | Profile discard alert | none | AppKit/SwiftUI confirmation behavior documented; no alert screenshot. |
| M07 | Conflict/reload profile | none | No conflict render; code/test evidence and ASCII. |
| M08 | Delete Bot confirmation | deletion | Impact/counts and destructive action disclosure. |
| M10 | Settings shell | provider-settings; appearance; export | Multiple top-level/final-state views; scrollable sections cannot all be seen in one screenshot. |
| M11 | Template/replacement review | provider-settings; router-settings | Provider selection/top viewport only; replacement confirmation not captured. |
| M12 | Compatible provider fields | provider-settings | Top viewport only; complete lower-field layout is in ASCII/source, not this PNG. |
| M13 | Local model discovery | router-settings | Offline scenario passes model catalog assertions; result controls below fold, not visually proven. |
| M14 | Codex configuration | codex-settings | Provider kind visible; full credential controls below fold. |
| M15 | Codex auth OS picker | none | OS-owned; synthetic importer tests do not screenshot its real file-selection/grant interaction. |
| M16 | Appearance/pane settings | appearance; appearance-minimum | Light/Dark/System workspace + Settings; System matches host effective theme. |
| M17 / M19 | Export section/result | export | Success/count/disclosure state; progress and failure not separately captured. |
| M18 | JSON Save/overwrite | none | OS-owned; fixture injects destination instead of automating Save Panel. |
| M20 / M20A | Routine editor | routine | Complete fixture editor; family navigation described in ASCII. |
| M20B | Routine status/history | routine | Scrollable history viewport, not all records. |
| M20C | Run Now review | none | Not separately captured; cannot use editor screenshot as proof of this consent. |
| M20D | Delete routine review | none | Not separately captured; documented from source/test evidence. |
| C02 / C03 / C04 | External terminal/proposed viewers | none | Not app-integrated. Private prior terminal capture was blank; proposed ASCII is explicitly labeled. |
| R01–R08 | Original reference surfaces | private archive | Eight original private source images indexed separately, not bundled as app output. |

## Capture limitations and duplicate-state notes

1. **Settings:** provider/router/Codex screenshots show the top of the scrollable window, stopping as Connection begins. Full model, URL, key/import controls are documented in M12–M15, but not visually proven by those captures.
2. **Group editor:** its current capture lacks visible Cancel/Save footer. Do not call the screenshot a complete editor-layout acceptance pass.
3. **Scrollable views:** routine history, attachment metadata and the first reply transcript bubble are partly outside their viewports. Consent/footer controls are visible in attachment review; full metadata is not.
4. **Small windows:** truncated sidebar rows and partially scrolled transcript are expected viewport evidence; minimum composer visibility is demonstrated, not every row or focus event.
5. **Aliases:** `mention--desktop-durable-workspace.png` and its minimum variant duplicate the explicit invalid-Dark mention image. They are not baseline workspaces. Unread and appearance final generic aliases also represent their final scenario states, not empty/first-launch workspaces.
6. **Theme duplicates:** Follow System can produce the same pixels as Dark on this host. Repeated Light captures share filenames; the script records those repeated emitted paths but the gallery lists each file once.
7. **Uncaptured states:** Create Bot, Marketplace, local profile, hidden/search-specific menus, error overlays, transient discard/replace/run/delete confirmations, live streaming failure variants, and real OS panels remain source/ASCII-only in this dump. No fake image is supplied for them.

## Scenario commands and measured results

All commands below were executed by the fixed capture runner in this audit. They use the current native scripts from the repository root.

| Scenario | Command | Exit | Unique PNG paths |
|---|---|---|---|
| sample-chat | `scripts/native-prototype.sh snapshot` | 0 | 1 |
| sample-picker | `scripts/native-prototype.sh snapshot --picker` | 0 | 1 |
| sample-group-picker | `scripts/native-prototype.sh snapshot --group` | 0 | 1 |
| workspace | `scripts/native-app.sh smoke` | 0 | 1 |
| workspace-minimum | `scripts/native-app.sh smoke --minimum` | 0 | 1 |
| provider-chat | `scripts/native-app.sh provider-smoke` | 0 | 1 |
| provider-settings | `scripts/native-app.sh provider-smoke --settings` | 0 | 1 |
| router-settings | `scripts/native-app.sh provider-smoke --router-models` | 0 | 1 |
| codex-chat | `scripts/native-app.sh codex-smoke` | 0 | 1 |
| codex-settings | `scripts/native-app.sh codex-smoke --settings` | 0 | 1 |
| edit-bot | `scripts/native-app.sh profile-smoke` | 0 | 1 |
| edit-group | `scripts/native-app.sh profile-smoke --edit-group` | 0 | 1 |
| reply | `scripts/native-app.sh reply-smoke` | 0 | 1 |
| export | `scripts/native-app.sh export-smoke` | 0 | 1 |
| deletion | `scripts/native-app.sh deletion-smoke` | 0 | 2 |
| routine | `scripts/native-app.sh routine-smoke` | 0 | 2 |
| attachment | `scripts/native-app.sh attachment-smoke` | 0 | 2 |
| appearance | `scripts/native-app.sh appearance-smoke` | 0 | 7 |
| appearance-minimum | `scripts/native-app.sh appearance-smoke --minimum` | 0 | 7 |
| unread | `scripts/native-app.sh unread-smoke --fixture-foreground` | 0 | 4 |
| group-round | `scripts/native-app.sh group-smoke` | 0 | 3 |
| group-round-minimum | `scripts/native-app.sh group-smoke --minimum` | 0 | 3 |
| mention | `scripts/native-app.sh mention-smoke` | 0 | 7 |
| mention-minimum | `scripts/native-app.sh mention-smoke --minimum` | 0 | 7 |

```sh
python3 scripts/capture-screen-atlas.py --list
python3 scripts/capture-screen-atlas.py
python3 scripts/verify-screen-atlas.py
```

Capture logs and raw output remain in the ignored local-only capture run directory. Publishing images requires separate review; the helper never stages, commits or uploads. Runtime tests were rerun with `scripts/native-app.sh test`: **300 core + 264 native shell = 564 tests, zero failures**, command exit 0. This is fresh offline evidence, not release, real-provider or physical OS-panel certification.

## Complete PNG inventory

Click any image link to see its full native render. Scenario labels and captions are part of the evidence contract; filenames alone can be misleading.

### S01 — sample-chat--desktop-chat.png
[Open native screenshot](screenshots/sample-chat--desktop-chat.png) · 1280×880 PNG pixels · scenario `sample-chat`

Synthetic native fixture render; no physical interaction or live provider claim.

### S02 — sample-picker--desktop-picker.png
[Open native screenshot](screenshots/sample-picker--desktop-picker.png) · 1280×880 PNG pixels · scenario `sample-picker`

Synthetic native fixture render; no physical interaction or live provider claim.

### S03 — sample-group-picker--desktop-group.png
[Open native screenshot](screenshots/sample-group-picker--desktop-group.png) · 1280×880 PNG pixels · scenario `sample-group-picker`

Synthetic native fixture render; no physical interaction or live provider claim.

### S04 — workspace--desktop-durable-workspace.png
[Open native screenshot](screenshots/workspace--desktop-durable-workspace.png) · 1280×880 PNG pixels · scenario `workspace`

Synthetic native fixture render; no physical interaction or live provider claim.

### S05 — workspace-minimum--small-durable-workspace.png
[Open native screenshot](screenshots/workspace-minimum--small-durable-workspace.png) · 760×632 PNG pixels · scenario `workspace-minimum`

Synthetic native fixture render; no physical interaction or live provider claim.

### S06 — provider-chat--desktop-provider-chat.png
[Open native screenshot](screenshots/provider-chat--desktop-provider-chat.png) · 1280×880 PNG pixels · scenario `provider-chat`

Synthetic native fixture render; no physical interaction or live provider claim.

### S07 — provider-settings--desktop-provider-settings.png
[Open native screenshot](screenshots/provider-settings--desktop-provider-settings.png) · 580×772 PNG pixels · scenario `provider-settings`

Top-of-Settings viewport only. Connection/model/key controls continue below the fold; this is not full provider-field visual evidence.

### S08 — router-settings--desktop-router-model-settings.png
[Open native screenshot](screenshots/router-settings--desktop-router-model-settings.png) · 580×772 PNG pixels · scenario `router-settings`

Top-of-Settings viewport only. Router fixture selection is visible; discovered model controls below the fold are not shown.

### S09 — codex-chat--desktop-codex-chat.png
[Open native screenshot](screenshots/codex-chat--desktop-codex-chat.png) · 1280×880 PNG pixels · scenario `codex-chat`

Synthetic native fixture render; no physical interaction or live provider claim.

### S10 — codex-settings--desktop-codex-settings.png
[Open native screenshot](screenshots/codex-settings--desktop-codex-settings.png) · 580×772 PNG pixels · scenario `codex-settings`

Top-of-Settings viewport only. Experimental provider selection is visible; auth/import controls below the fold are not shown.

### S11 — edit-bot--desktop-edit-bot.png
[Open native screenshot](screenshots/edit-bot--desktop-edit-bot.png) · 480×553 PNG pixels · scenario `edit-bot`

Synthetic native fixture render; no physical interaction or live provider claim.

### S12 — edit-group--desktop-edit-group.png
[Open native screenshot](screenshots/edit-group--desktop-edit-group.png) · 480×553 PNG pixels · scenario `edit-group`

Group editor viewport is clipped before Cancel/Save footer; source/ASCII document those controls, this image does not prove footer visibility.

### S13 — reply--desktop-reply-chat.png
[Open native screenshot](screenshots/reply--desktop-reply-chat.png) · 1280×880 PNG pixels · scenario `reply`

Reply reference/composer are visible; the first transcript bubble is clipped at the top viewport.

### S14 — export--desktop-export-settings.png
[Open native screenshot](screenshots/export--desktop-export-settings.png) · 580×772 PNG pixels · scenario `export`

Synthetic native fixture render; no physical interaction or live provider claim.

### S15 — deletion--desktop-delete-confirmation.png
[Open native screenshot](screenshots/deletion--desktop-delete-confirmation.png) · 500×411 PNG pixels · scenario `deletion`

Synthetic native fixture render; no physical interaction or live provider claim.

### S16 — deletion--desktop-degraded-group.png
[Open native screenshot](screenshots/deletion--desktop-degraded-group.png) · 1280×880 PNG pixels · scenario `deletion`

Synthetic native fixture render; no physical interaction or live provider claim.

### S17 — routine--desktop-routine-editor.png
[Open native screenshot](screenshots/routine--desktop-routine-editor.png) · 480×693 PNG pixels · scenario `routine`

Editor is complete; history capture stops partway through a record and does not show the full scrollable history.

### S18 — routine--desktop-routine-history.png
[Open native screenshot](screenshots/routine--desktop-routine-history.png) · 600×550 PNG pixels · scenario `routine`

Editor is complete; history capture stops partway through a record and does not show the full scrollable history.

### S19 — attachment--desktop-attachment-confirmation.png
[Open native screenshot](screenshots/attachment--desktop-attachment-confirmation.png) · 520×560 PNG pixels · scenario `attachment`

Consent is visible; attachment metadata continues below the visible scroll area/fixed footer. This is injected selection, not the real OS picker.

### S20 — attachment--desktop-durable-workspace.png
[Open native screenshot](screenshots/attachment--desktop-durable-workspace.png) · 1280×880 PNG pixels · scenario `attachment`

Final state of this named fixture scenario, NOT a first-launch baseline. Consent is visible; attachment metadata continues below the visible scroll area/fixed footer. This is injected selection, not the real OS picker.

### S21 — appearance--desktop-appearance-light-workspace.png
[Open native screenshot](screenshots/appearance--desktop-appearance-light-workspace.png) · 1280×880 PNG pixels · scenario `appearance`

Synthetic native fixture render; no physical interaction or live provider claim.

### S22 — appearance--desktop-appearance-light-settings.png
[Open native screenshot](screenshots/appearance--desktop-appearance-light-settings.png) · 580×772 PNG pixels · scenario `appearance`

Synthetic native fixture render; no physical interaction or live provider claim.

### S23 — appearance--desktop-appearance-dark-workspace.png
[Open native screenshot](screenshots/appearance--desktop-appearance-dark-workspace.png) · 1280×880 PNG pixels · scenario `appearance`

Synthetic native fixture render; no physical interaction or live provider claim.

### S24 — appearance--desktop-appearance-dark-settings.png
[Open native screenshot](screenshots/appearance--desktop-appearance-dark-settings.png) · 580×772 PNG pixels · scenario `appearance`

Synthetic native fixture render; no physical interaction or live provider claim.

### S25 — appearance--desktop-appearance-system-workspace.png
[Open native screenshot](screenshots/appearance--desktop-appearance-system-workspace.png) · 1280×880 PNG pixels · scenario `appearance`

Synthetic native fixture render; no physical interaction or live provider claim. Identical PNG content to S23 (different alias/theme record).

### S26 — appearance--desktop-appearance-system-settings.png
[Open native screenshot](screenshots/appearance--desktop-appearance-system-settings.png) · 580×772 PNG pixels · scenario `appearance`

Synthetic native fixture render; no physical interaction or live provider claim.

### S27 — appearance--desktop-durable-workspace.png
[Open native screenshot](screenshots/appearance--desktop-durable-workspace.png) · 1280×880 PNG pixels · scenario `appearance`

Final state of this named fixture scenario, NOT a first-launch baseline. Synthetic native fixture render; no physical interaction or live provider claim.

### S28 — appearance-minimum--small-appearance-light-workspace.png
[Open native screenshot](screenshots/appearance-minimum--small-appearance-light-workspace.png) · 760×632 PNG pixels · scenario `appearance-minimum`

760×600 content request; titlebar/raster pixels differ. Truncated sidebar text and offscreen transcript are viewport states; composer fits.

### S29 — appearance-minimum--small-appearance-light-settings.png
[Open native screenshot](screenshots/appearance-minimum--small-appearance-light-settings.png) · 580×772 PNG pixels · scenario `appearance-minimum`

760×600 content request; titlebar/raster pixels differ. Truncated sidebar text and offscreen transcript are viewport states; composer fits. Identical PNG content to S22 (different alias/theme record).

### S30 — appearance-minimum--small-appearance-dark-workspace.png
[Open native screenshot](screenshots/appearance-minimum--small-appearance-dark-workspace.png) · 760×632 PNG pixels · scenario `appearance-minimum`

760×600 content request; titlebar/raster pixels differ. Truncated sidebar text and offscreen transcript are viewport states; composer fits.

### S31 — appearance-minimum--small-appearance-dark-settings.png
[Open native screenshot](screenshots/appearance-minimum--small-appearance-dark-settings.png) · 580×772 PNG pixels · scenario `appearance-minimum`

760×600 content request; titlebar/raster pixels differ. Truncated sidebar text and offscreen transcript are viewport states; composer fits. Identical PNG content to S24 (different alias/theme record).

### S32 — appearance-minimum--small-appearance-system-workspace.png
[Open native screenshot](screenshots/appearance-minimum--small-appearance-system-workspace.png) · 760×632 PNG pixels · scenario `appearance-minimum`

760×600 content request; titlebar/raster pixels differ. Truncated sidebar text and offscreen transcript are viewport states; composer fits. Identical PNG content to S30 (different alias/theme record).

### S33 — appearance-minimum--small-appearance-system-settings.png
[Open native screenshot](screenshots/appearance-minimum--small-appearance-system-settings.png) · 580×772 PNG pixels · scenario `appearance-minimum`

760×600 content request; titlebar/raster pixels differ. Truncated sidebar text and offscreen transcript are viewport states; composer fits. Identical PNG content to S26 (different alias/theme record).

### S34 — appearance-minimum--small-durable-workspace.png
[Open native screenshot](screenshots/appearance-minimum--small-durable-workspace.png) · 760×632 PNG pixels · scenario `appearance-minimum`

Final state of this named fixture scenario, NOT a first-launch baseline. 760×600 content request; titlebar/raster pixels differ. Truncated sidebar text and offscreen transcript are viewport states; composer fits.

### S35 — unread--desktop-unread-dark-before.png
[Open native screenshot](screenshots/unread--desktop-unread-dark-before.png) · 1280×880 PNG pixels · scenario `unread`

Synthetic foreground gate explicitly injected; not proof of real active/key-window reading acknowledgement.

### S36 — unread--desktop-unread-light-before.png
[Open native screenshot](screenshots/unread--desktop-unread-light-before.png) · 1280×880 PNG pixels · scenario `unread`

Synthetic foreground gate explicitly injected; not proof of real active/key-window reading acknowledgement.

### S37 — unread--desktop-unread-after.png
[Open native screenshot](screenshots/unread--desktop-unread-after.png) · 1280×880 PNG pixels · scenario `unread`

Synthetic foreground gate explicitly injected; not proof of real active/key-window reading acknowledgement.

### S38 — unread--desktop-durable-workspace.png
[Open native screenshot](screenshots/unread--desktop-durable-workspace.png) · 1280×880 PNG pixels · scenario `unread`

Final state of this named fixture scenario, NOT a first-launch baseline. Synthetic foreground gate explicitly injected; not proof of real active/key-window reading acknowledgement.

### S39 — group-round--desktop-group-composer-light.png
[Open native screenshot](screenshots/group-round--desktop-group-composer-light.png) · 1280×880 PNG pixels · scenario `group-round`

Synthetic native fixture render; no physical interaction or live provider claim.

### S40 — group-round--desktop-group-composer-dark.png
[Open native screenshot](screenshots/group-round--desktop-group-composer-dark.png) · 1280×880 PNG pixels · scenario `group-round`

Synthetic native fixture render; no physical interaction or live provider claim.

### S41 — group-round--desktop-group-round-confirmation.png
[Open native screenshot](screenshots/group-round--desktop-group-round-confirmation.png) · 520×560 PNG pixels · scenario `group-round`

Synthetic native fixture render; no physical interaction or live provider claim.

### S42 — group-round-minimum--small-group-composer-light.png
[Open native screenshot](screenshots/group-round-minimum--small-group-composer-light.png) · 760×632 PNG pixels · scenario `group-round-minimum`

Minimum-size window; recipient area is constrained/scrollable. This is rendered disclosure, not physical Send/Stop input.

### S43 — group-round-minimum--small-group-composer-dark.png
[Open native screenshot](screenshots/group-round-minimum--small-group-composer-dark.png) · 760×632 PNG pixels · scenario `group-round-minimum`

Minimum-size window; recipient area is constrained/scrollable. This is rendered disclosure, not physical Send/Stop input.

### S44 — group-round-minimum--small-group-round-confirmation.png
[Open native screenshot](screenshots/group-round-minimum--small-group-round-confirmation.png) · 520×560 PNG pixels · scenario `group-round-minimum`

Minimum-size window; recipient area is constrained/scrollable. This is rendered disclosure, not physical Send/Stop input. Identical PNG content to S41 (different alias/theme record).

### S45 — mention--desktop-mention-composer-light.png
[Open native screenshot](screenshots/mention--desktop-mention-composer-light.png) · 1280×880 PNG pixels · scenario `mention`

Generic durable-workspace alias is the same invalid-Dark state, not a pristine workspace; use explicit mention filenames.

### S46 — mention--desktop-mention-composer-dark.png
[Open native screenshot](screenshots/mention--desktop-mention-composer-dark.png) · 1280×880 PNG pixels · scenario `mention`

Generic durable-workspace alias is the same invalid-Dark state, not a pristine workspace; use explicit mention filenames.

### S47 — mention--desktop-mention-confirmation-light.png
[Open native screenshot](screenshots/mention--desktop-mention-confirmation-light.png) · 520×560 PNG pixels · scenario `mention`

Generic durable-workspace alias is the same invalid-Dark state, not a pristine workspace; use explicit mention filenames.

### S48 — mention--desktop-mention-confirmation-dark.png
[Open native screenshot](screenshots/mention--desktop-mention-confirmation-dark.png) · 520×560 PNG pixels · scenario `mention`

Generic durable-workspace alias is the same invalid-Dark state, not a pristine workspace; use explicit mention filenames.

### S49 — mention--desktop-mention-invalid-light.png
[Open native screenshot](screenshots/mention--desktop-mention-invalid-light.png) · 1280×880 PNG pixels · scenario `mention`

Generic durable-workspace alias is the same invalid-Dark state, not a pristine workspace; use explicit mention filenames.

### S50 — mention--desktop-mention-invalid-dark.png
[Open native screenshot](screenshots/mention--desktop-mention-invalid-dark.png) · 1280×880 PNG pixels · scenario `mention`

Generic durable-workspace alias is the same invalid-Dark state, not a pristine workspace; use explicit mention filenames.

### S51 — mention--desktop-durable-workspace.png
[Open native screenshot](screenshots/mention--desktop-durable-workspace.png) · 1280×880 PNG pixels · scenario `mention`

Alias of invalid-Dark mention state, NOT a normal baseline workspace. Generic durable-workspace alias is the same invalid-Dark state, not a pristine workspace; use explicit mention filenames. Identical PNG content to S50 (different alias/theme record).

### S52 — mention-minimum--small-mention-composer-light.png
[Open native screenshot](screenshots/mention-minimum--small-mention-composer-light.png) · 760×632 PNG pixels · scenario `mention-minimum`

Minimum-size fixture. Explicit mention states are valid coverage; generic durable-workspace alias is the same invalid-Dark state.

### S53 — mention-minimum--small-mention-composer-dark.png
[Open native screenshot](screenshots/mention-minimum--small-mention-composer-dark.png) · 760×632 PNG pixels · scenario `mention-minimum`

Minimum-size fixture. Explicit mention states are valid coverage; generic durable-workspace alias is the same invalid-Dark state.

### S54 — mention-minimum--small-mention-confirmation-light.png
[Open native screenshot](screenshots/mention-minimum--small-mention-confirmation-light.png) · 520×560 PNG pixels · scenario `mention-minimum`

Minimum-size fixture. Explicit mention states are valid coverage; generic durable-workspace alias is the same invalid-Dark state.

### S55 — mention-minimum--small-mention-confirmation-dark.png
[Open native screenshot](screenshots/mention-minimum--small-mention-confirmation-dark.png) · 520×560 PNG pixels · scenario `mention-minimum`

Minimum-size fixture. Explicit mention states are valid coverage; generic durable-workspace alias is the same invalid-Dark state.

### S56 — mention-minimum--small-mention-invalid-light.png
[Open native screenshot](screenshots/mention-minimum--small-mention-invalid-light.png) · 760×632 PNG pixels · scenario `mention-minimum`

Minimum-size fixture. Explicit mention states are valid coverage; generic durable-workspace alias is the same invalid-Dark state.

### S57 — mention-minimum--small-mention-invalid-dark.png
[Open native screenshot](screenshots/mention-minimum--small-mention-invalid-dark.png) · 760×632 PNG pixels · scenario `mention-minimum`

Minimum-size fixture. Explicit mention states are valid coverage; generic durable-workspace alias is the same invalid-Dark state.

### S58 — mention-minimum--small-durable-workspace.png
[Open native screenshot](screenshots/mention-minimum--small-durable-workspace.png) · 760×632 PNG pixels · scenario `mention-minimum`

Alias of invalid-Dark mention state, NOT a normal baseline workspace. Minimum-size fixture. Explicit mention states are valid coverage; generic durable-workspace alias is the same invalid-Dark state. Identical PNG content to S57 (different alias/theme record).
