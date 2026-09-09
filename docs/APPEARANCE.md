# Native appearance and layout preferences

The durable app offers **Dark**, **Light** and **Follow System** in Settings.
Dark remains the default, preserving the original reference palette. Light uses
semantic light surfaces and readable text/warning colors rather than white text
on fixed dark panels.

## Settings contract

- Appearance and preferred sidebar/inspector visibility use a detached edit buffer.
  **Save Appearance** applies it; **Cancel Changes** reloads the current saved values.
  Closing Settings or quitting with unsaved appearance/provider edits asks before
  discarding them. Saving appearance does not save or discard provider credentials.
- Save updates the workspace, separate Settings window and inherited sheets. It does
  not recreate the workspace store or replace the composer/transcript hierarchy.
- Divider adjustments persist independently. A Settings save retains divider changes
  made while that form was open. Sidebar bounds are 240–400pt; inspector bounds
  are 280–440pt. Invalid/non-finite persisted widths recover to safe defaults.
- At the 760pt minimum content width, a saved 400pt sidebar is temporarily displayed
  at 335pt so the chat retains 424pt plus its divider. This does not overwrite the
  saved 400pt preference. Inspector auto-collapse similarly preserves the preferred
  visibility and returns when space permits.
- Hidden-conversation search filtering remains explicitly session-only. UI preferences
  are separate from Core Data conversation content and workspace export.

## Implementation and isolation

`WorkspacePreferencesStorage` uses a versioned, app-owned UserDefaults dictionary
containing only appearance, two widths and two visibility values. Loading does not
write defaults or erase unrelated keys. Unknown/invalid individual fields recover
independently; the original record is not rewritten just by opening the app.
Normal durable launches use the app's preferences. Tests and the sample preview default
to isolated in-memory preferences; the appearance smoke injects a uniquely named suite
and removes only that suite afterwards. No normal user preference or OS appearance
setting is changed by the smoke.

Follow System clears the app appearance override and leaves windows inheriting it.
Apple documents that a nil app appearance follows the current system appearance and
that individual window/view overrides must also be considered. [App appearance](https://developer.apple.com/documentation/appkit/nsapplication/appearance),
[inherited appearance](https://developer.apple.com/documentation/appkit/nsappearancecustomization/appearance).

The existing `ShellTheme` supplies dynamic NSColors resolved using the appearance
provided by AppKit; `Color(nsColor:)` retains their adaptive behavior. The native
composer installs adaptive text/caret colors rather than rewriting them on every
SwiftUI update. [Dynamic NSColor](https://developer.apple.com/documentation/appkit/nscolor/init(name:dynamicprovider:)),
[SwiftUI color bridge](https://developer.apple.com/documentation/swiftui/color/init(nscolor:)).

## Verification and limitations

Preference tests cover isolated persistence/recreation, invalid field types, finite
bounds, unknown appearance values and preservation of unrelated defaults. Native
workflow tests cover store observation, detached edits, draft retention and narrow
layout behavior. Theme tests lock the original dark palette and the light palette,
measure text contrast and exercise a hosted composer's identity/text/selection across
an actual window appearance change.

```sh
scripts/native-app.sh appearance-smoke
scripts/native-app.sh appearance-smoke --minimum
```

The smoke switches Light → Dark → Follow System → Light in a synthetic workspace,
checks the app and Settings appearance, recreates preference storage, reopens the
workspace, checks retained drafts/messages and renders both windows. The minimum
variant uses a 760×600 content request. It does not automate physical Settings input
or toggle the user's OS appearance setting.

On this host, AppKit can commit synthetic marked text during an effective-appearance
change while preserving the document and selection. The app does **not** asynchronously
recreate a composition after that commit: an intentional user commit can leave the
same text, so text equality is not authority to restore IME state. Physical Thai/CJK
IME, automatic OS-appearance changes during composition, VoiceOver, high-contrast
modes and macOS 14 runtime behavior remain explicit R09/T14 validation gaps. No
power-loss durability or complete accessibility conformance is claimed by these tests.

The full [native rewrite contract](NATIVE-REWRITE-CONTRACT.md) remains in force;
this is appearance/layout progress, not completion of all product or release gates.
