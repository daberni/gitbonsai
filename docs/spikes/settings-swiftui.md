# Spike: settings window in SwiftUI

Branch `task/settings-swiftui`. The settings window is the app's first SwiftUI surface. All five sections are rebuilt as grouped SwiftUI `Form`s; the window and its toolbar tabs stay AppKit.

## Verdict

**Adopt SwiftUI for settings.** The rebuild is shorter, reads like the system settings on macOS 26, and keeps the design tokens, the String Catalog and the harness.

Next candidates, roughly in this order:

1. The welcome page. It is a static layout.
2. Form sheets: clone, new branch, `ActionForm` and the failure sheet.
3. Future side panels.

Keep AppKit for the history, the diff, the sidebar, the command bar and anything else with custom drawing, large lists or custom key handling.

Three costs come with SwiftUI. Each new surface pays them once:

- **Accessibility identifiers for the harness.** SwiftUI publishes its accessibility tree only after the harness turns it on (below). Some controls also need an identifier, because a grouped `Form` leaves the switch's own label empty.
- **Verbose localization calls.** Every string is `LocalizedStringResource("key", defaultValue: "…", bundle: .module, comment: …)` at the call site. A helper would hide the literal from the compiler's string extraction.
- **No content-sized windows for free.** A grouped `Form` is a scroll view, so the window height comes from measuring it (`onScrollGeometryChange`) and capping that.

## How it is built

| Part | Choice | Why |
|---|---|---|
| Window and tabs | `NSTabViewController` with `.toolbar` style, one `NSHostingController` per section, `toolbarStyle = .preference` | The app starts through `main.swift` and `AppDelegate`, so the SwiftUI `Settings` scene is not available. A SwiftUI `TabView` outside that scene draws a segmented control, not toolbar tabs. |
| Section sizing | `Form { }.formStyle(.grouped)` whose height follows `onScrollGeometryChange` (content height plus insets), capped at `Theme.Settings.maxHeight` (600 pt), with `sizingOptions = .preferredContentSize` | The window takes each section's height, as before; a taller section stops at the cap and scrolls. |
| State | `SettingsModel` (`@Observable`) | Its computed properties read and write `AppSettings` directly. A `revision` counter follows `AppSettings.didChange`, so changes from anywhere redraw. `@Bindable` gives the bindings. There is no second copy of any preference. |
| Tokens | `DesignTokens+SwiftUI.swift` (40 lines) | `Color(nsColor: Theme.x)` keeps the dynamic light/dark colours. `Font(Theme.caption as CTFont)` gives the same font faces. Spacing and sizes are the plain `CGFloat`s in `Theme`. |
| Pill | `PillLabel` | Same ground as the muted ref pills (`inkMuted` mixed into `surface0` at `Theme.Pill.tint.plain`), the `RefText` padding and the pill font. It has no glyph, since "Default" names no ref. |
| Open panels | `.fileImporter` with `.fileDialogDefaultDirectory`, `.fileDialogConfirmationLabel` and `.fileDialogMessage` | Pure SwiftUI; no `NSOpenPanel` code is left. |
| Strings | The semantic keys main already had for the AppKit panes (`settings.pane.*`, `settings.git.program.label`, `common.add`, `common.default`, …), new keys only for new text (`settings.pane.apps`, `settings.apps.makeDefault`, the Apps captions) | `Text(LocalizedStringResource(…, defaultValue:, bundle: .module))` resolves from `Bundle.module` and follows `GITBONSAI_LANGUAGE`; `LocalizationTests` passes unchanged. |

### Behaviour compared with the AppKit window

The same:

- Git path: placeholder with the found git, commit on Return or focus loss, refusal of a non-executable path, version check, ochre warning below 2.38, red text for a program that is not git.
- Appearance and language choices.
- Fetch on activation and the interval.
- Avatars with the sources disabled while avatars are off. `AvatarStore` still deletes the caches when avatars are turned off.
- Repository folders and adding apps.

Changed, from the backlog:

- **Simpler editor and terminal settings** (done here). The default popup is gone. Each row has its checkbox (offered in the command bar), icon and name. The default carries a pill. Any other checked row shows "Make default" while the pointer is on it, and has the same entry in its context menu and as a VoiceOver action. Unchecking the default falls back to the first checked app, as before. Editors and terminals share one component.
- **"Standard" label as a pill** (done for settings). It uses the `PillLabel` above. Menus, such as the default pull variant, still need their own change.
- **Editor per repository** (`gitbonsai.editor`, not done). It does not fit the app-wide window. It needs a repository context, two new git calls (`git config [--unset] gitbonsai.editor`) and a `GitEngine` API, which is a coordinator contract. It stays in the backlog.

Sections, after review: editors and terminals moved out of General into their own **Apps** tab; General holds the repository folders and the interface language (moved from Appearance, which keeps the colour scheme and will take themes). Their keys moved with them (`settings.general.language.*`, `settings.apps.editors.*`, `settings.apps.terminals.*`).

Changed for the platform:

- Toggles are trailing switches, as in grouped forms on macOS 26.
- "Color scheme" is a segmented control; language and interval are menus.
- Folders have a remove button per row instead of a selection with `+`/`−`. "Add folder…" and "Add other app…" are the last row of their section.

### Numbers

| | AppKit | SwiftUI |
|---|---|---|
| Settings UI code (window, form helper, sections, app list, folder list) | 647 lines in 9 files | 642 lines in 11 files |
| …of which model and token bridge | – | 134 (`SettingsModel` 94, `DesignTokens+SwiftUI` 40) |
| …section and list views only | 647 | 508 |
| Harness switch file | 24 (capture only) | 141 (capture plus `GITBONSAI_SETTINGS_SCRIPT`) |
| `Theme.Settings` and `Theme.Editors` tokens | 13 | 5 |

Most SwiftUI lines are long because of the localized resource calls. The layout code itself is much smaller: no grid, no constraints, no table data sources.

## Harness

- **Captures.** `cacheDisplay` on the frame view renders SwiftUI hosting views correctly, including grouped form backgrounds and switches. `GITBONSAI_SETTINGS=<section>` works unchanged.
- **Reading.** SwiftUI builds its accessibility tree only when an assistive client asks for it. The harness sets `AXEnhancedUserInterface` on its own `NSApp`, the attribute VoiceOver sets. After that, `accessibilityChildren()` from the window down reaches SwiftUI's nodes. The nodes do not declare `NSAccessibilityProtocol` to Swift, so the harness queries them through `AnyObject`. `print` lists role, label, value, identifier and enabled state.
- **Driving.** The harness sends real mouse events at an element's accessibility frame, converted to window coordinates, and takes the existing `click(in:at:)` path. Verified:
  - checkboxes, off and on again (a grouped form makes a checkbox span its row, so the click goes to the box at the leading edge);
  - switches in both directions;
  - toolbar tabs, with the window resizing to the section;
  - scrolling a capped section with a scroll-wheel event (`scroll:<points>`, which prints the offset);
  - focus in the text field, typing, and Return.
- **Named actions.** `action:<element>=<name>` performs a named accessibility action. It drives "Make default" without hover.
- **Not driven:**
  - pop-up menus;
  - the `.fileImporter` panels;
  - hover;
  - Tab moving out of a text field (the same as AppKit without Full Keyboard Access);
  - ⌘W, which needs a key window, and background runs never get one. Its `AppDelegate` path is unchanged. ⌘, through the main menu opens the SwiftUI window: `GITBONSAI_COMMAND_BAR="shortcut:cmd-,;windows"` printed `windows: main, General`.

A pre-existing problem showed up along the way. All sessions and runs share the defaults domain `app.gitbonsai.harness`. Another session's runs set `repositoryFolders = ()` and changed the default terminal during this spike. A git path typed in by a script persists for later runs until it is deleted. A domain per run, or per `GITBONSAI_*` session, would make runs independent.

## Accessibility, focus and keyboard

- VoiceOver gets headings for the sections, labelled checkboxes per app, radio buttons, the popup with its value, and the captions as static text.
- **Gap: the switches' AX label is empty.** The grouped form puts the switch's label into a separate static text. VoiceOver reads the row, but a lookup by label finds the text, not the control. `.accessibilityIdentifier` covers the harness. A real fix is an explicit `.accessibilityLabel` on such toggles, which is still to do.
- **Gap: a transparent view leaves the tree.** SwiftUI drops a view with `.opacity(0)` from the accessibility tree, so the hover-only "Make default" button had to be complemented by a named action and a context-menu entry.
- **Focus rings and keyboard.** Focus rings and the default keyboard behaviour come from the platform controls. Full Keyboard Access is needed to Tab between buttons, as in AppKit.

## Visual result

- The grouped form, toolbar tabs and switches are the macOS 26 system look with Liquid Glass toolbar buttons. Light and dark follow `NSApp.appearance` with no extra code.
- Captions use the app's `inkMuted` caption style, and the warning colours `ochre` and `persimmon` come from the tokens.
- The Apps section with 7 editors and 2 terminals is 677 pt of content; it stops at 600 pt and scrolls as a whole, where the AppKit window scrolled two fixed-height lists.

Screenshots: `settings-swiftui-shots/` in the session notes folder.

- `appkit/` holds the originals.
- `swiftui/` holds the rebuild: `<en|de>-<section>-<light|dark>.png`, plus `git-old` with a fake git 2.30.1.

## Open

1. **Switch labels.** Add an explicit `.accessibilityLabel` to toggles in grouped forms.
2. **Harness pop-ups and panels.** Pop-up menus need a harness path, for example the popup's `AXPress` followed by choosing the menu item. Open panels are not driven.
3. **Editor per repository** stays in the backlog (see above).
4. **ScreenshotHarness switches.** The settings switches are in `ScreenshotHarness+Settings.swift`; the core harness file is untouched.
