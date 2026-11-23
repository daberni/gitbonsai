# GitBonsai — agent instructions

GitBonsai is a native macOS Git client with a graph-centric UX. The app is AppKit; self-contained forms and panels are SwiftUI hosted in AppKit (the settings window today). The main window with tabs, toolbar, sidebar, history, detail panel, diff and command bar stays AppKit, because it needs custom drawing, large lists and custom key handling. The rule and its reasons are in `docs/architecture.md` section 1.1. Every Git operation runs through the native `git` binary; nothing is reimplemented that git itself provides.

## Principles

1. **CLI only.** All repository reads and writes go through `GitRunner` in `GitEngine`. No libgit2, no hand-parsed `.git` internals except reading `HEAD`/refs for file watching. Parsers consume stable machine formats (`--porcelain=v2`, `-z`, `--format=` with NUL separators).
2. **No AI features, no embedded terminal, no cloud.** Only "Open in Terminal/Editor/Finder".
3. **Lazy everything.** `git log` is streamed and laid out incrementally; the graph is virtualized and drawn with CoreGraphics in AppKit views. Never one SwiftUI view per commit.
4. **Worktrees are first class.**
5. **Every action shows its git command** (command log).

## Layout

- `Sources/GitEngine` — process runner, models, parsers, `Repository` facade. Pure Swift, no AppKit. Fully testable against real repos created in tests.
- `Sources/GraphLayout` — incremental lane layout for the commit graph. Pure functions over `Commit` values.
- `Sources/GitBonsaiApp` — the app (`swift run GitBonsaiApp <repo>`). One type per responsibility:
  - Window: `MainWindowController` (tabs, opening, title bar), `TabBarView`, `WelcomeView`, `SessionStore`.
  - Repository tab: `RepositoryViewController` only assembles the parts and routes `GraphViewModel` changes to them; `RepositoryToolbar`, `SidebarView`, `DetailView`, `CheckoutController`.
  - History: `HistoryViewController` (table, selection, search), `HistoryColumnsController` (widths, visibility, graph scroll, column menu), `HistoryColumns` (layout math and `ColumnStore`), `HistoryViews` (header, table, hover guide), `HistoryRowModel` (row and label models), `GraphRowView` (drawing).
  - Shared: the design tokens in `DesignTokens.swift` (shared scales) and `DesignTokens+<Area>.swift` (component namespaces by area: Window, History, Detail, Sheets, SwiftUI bridge), `Glyphs`, `ChromeViews`. `ScreenshotHarness` holds all verification switches.
  - When a type starts mixing responsibilities or passes about 300 lines, split it before adding more.
  - Minimum is macOS 26. A SwiftPM build records the minimum as its SDK version, and AppKit draws the current window style (larger traffic lights, Liquid Glass controls) only for SDK 26 and later. An Xcode-built app bundle records the real SDK; revisit the minimum once the app is packaged that way.
  - No literal sizes, spacings, radii, strokes, fonts or alphas in views. Use the scales in `Theme` (colours, fonts, `Space`, `Radius`, `Stroke`, `Icon`, `Wash`, `Focus`), which mirror the shared scales in `docs/design/tokens.json`; sizes that belong to one component go only into its namespace in the matching `DesignTokens+<Area>.swift` (`Theme.Tabs`, `Theme.Sidebar`, …), not into `tokens.json`. Check a refactor of numbers with before/after screenshots: they must be pixel-identical apart from times.
- `Tests/` — XCTest. Fixture repos are built on the fly with `git` in a temp dir (see `GitEngineTests/FixtureRepo.swift`).
- `docs/` — product and architecture docs, design language.
- `scripts/` — app bundle, string catalog sync and synthetic-repository helpers.

## Working rules

- Build with `swift build`; test with `swift test`. Both must pass before a commit. The build stays free of compiler warnings, in debug and release (`swift build -c release`); a change fixes the warnings it introduces.
- Keep `GitEngine` and `GraphLayout` free of AppKit/SwiftUI imports.
- Run every `git` with `GIT_TERMINAL_PROMPT=0`, `-c core.quotepath=off`, `-c color.ui=never`; reads additionally with `GIT_OPTIONAL_LOCKS=0`.
- Parsers get a fixture test for every format they consume, including: unicode paths, renames, submodules, conflicts, detached HEAD, octopus merges, empty repo.
- Performance budgets are tests (`swift test --filter Performance`): first 300 commits laid out in < 100 ms; 100k commits laid out in < 2 s on Apple Silicon.
- Comments explain intent or constraints, never mechanics. Prefer complete statements over line-length wrapping.
- Commit messages: imperative subject that names the topic; a body with the context a reader of `git log` needs (why the change, what it decides, notable limits) whenever the subject alone does not carry it. No process narration, test logs or work-in-progress notes. Never hard-wrap: each paragraph and each list item is one line, the reader's tools wrap it.
- One topic, one compact commit: a topic is a backlog entry or a coherent part of one (an engine change and the UI on top of it), never a single finding, file or step. A task branch typically lands as one to three commits; the body lists what the topic covers. Each commit builds. Fix-ups, review rounds, renames and reverted attempts are squashed into the commit they belong to. History is curated before it reaches `main`, never dumped as it happened.
- [docs/git-operations.md](docs/git-operations.md) lists the git command behind every operation. A change that adds or changes a git call updates its rows there in the same commit.

## Code and architecture conventions

- Develop against the current state. Internal APIs, view types and module structure change together; update every caller in the same change instead of keeping old signatures, aliases or fallback paths for earlier versions.
- Keep types focused on one reason to change. A view draws or lays out one coherent part; a controller owns one interaction or use case; `GitEngine` owns every git call and parse. Split by responsibility instead of growing single files.
- Add behavior tests against real repositories for consequential logic: parsing, staging and patch building, history and layout rules, anything that rewrites refs or the index. Show the failure on the original defect when adding a regression test. Do not test drawing, trivial delegation or logging.
- New self-contained forms and panels (settings, form sheets, future side panels) may be SwiftUI in an `NSHostingController`; read design tokens through `DesignTokens+SwiftUI.swift`, localize with `LocalizedStringResource(…, bundle: .module)`, and give controls accessibility identifiers so the harness can drive them. Custom-drawn, large or keyboard-heavy views stay AppKit.
- Link-like clickable text and bare icons show the pointing hand through `LinkButton` or `LinkCursor`; bordered buttons, toolbar buttons, segmented controls, menus and table rows keep the arrow, as in native macOS apps.
- Verify UI changes in the running app through `ScreenshotHarness`, in light and dark. Interactions are checked with real mouse events through the window (see the click and drag switches in the README), not by calling the handler directly. Harness runs stay in the background; `GITBONSAI_FOREGROUND=1` is for a single check that cannot work otherwise, never for loops or batches, and only after telling the coordinator why.

## Localization

- English is the development language, German the first translation, both in `Sources/GitBonsaiApp/Resources/Localizable.xcstrings`. Keys are semantic; the English text is each key's source value. `scripts/sync-strings.sh` adds new keys with the English from the code, updates the English of changed ones (their German then needs review) and marks unused keys stale; translate, review or delete them in the same change. `LocalizationTests` fails on keys outside the scheme, missing English or German, German awaiting review, stale or unused keys, English in the code that differs from the catalog, duplicated meanings and literals that bypass the catalog.
- Call sites name the key and give the English: `String(localized: "history.status.loading", defaultValue: "Loading…", bundle: .module, comment: "…")` for AppKit, and for own APIs, which take a `LocalizedStringResource`, `LocalizedStringResource("commit.menu.reset", defaultValue: "Reset \(RefName.branch(name)) to here", bundle: .module)`. Always both `defaultValue:` and `bundle: .module`; the compiler only extracts these two initializers, so no wrapper helpers. Add a comment where the meaning is not obvious.
- Key scheme: dotted lowerCamelCase segments, `area.screen.element` (`settings.general.editors.label`, `history.status.loading`). Areas: `common` (words that mean the same everywhere: `common.cancel`, `common.delete`, `common.commitCount`), `menu` (menu bar), `window`, `welcome`, `repository`, `toolbar`, `sidebar`, `history`, `detail`, `diff`, `files`, `commit`, `branch`, `checkout`, `tag`, `stash`, `worktree`, `fetch`, `pull`, `push`, `rebase`, `operation` (banner of a running merge, rebase, cherry-pick or revert), `conflict` (the conflict view), `clone`, `settings`, `command` (command bar titles, keywords, reasons), `commandBar`, `refPicker`, `panel`, `failure` (titles and reasons of failed operations: `failure.pull.failed`, `failure.reason.uncommittedChanges`). Common elements: `title`, `info`, `confirm`, `label`, `caption`, `placeholder`, `toolTip`, `menu.<item>`, `action.<item>`.
- Reuse a key wherever the text means the same, including across areas (`failure.rebase.failed`); give the same English its own key when it means something else or may need another translation (`toolbar.pull.title` and `command.pull.title`, `history.column.commit` and `detail.commit.title`). Never reuse a key only because the English matches.
- Never build sentences by concatenation: one key per sentence with placeholders. Counts are `Int` arguments with plural variants in the catalog. Names (refs, commits, paths, worktrees, stashes) are `RefName` arguments, shown as pills through `RefString`; text shown as it is goes in with `.verbatim`.
- Dates, relative dates, numbers, durations and sizes use formatters with `AppLanguage.locale`; no fixed locales.
- Never translate git commands, the command line shown in the status line, git output, ref names, paths or SHAs.
- English capitalization for commands (menus, command bar, buttons, sheet titles): capitalize the verb and the git object (Commit, Branch, Tag, Worktree, Remote, Stash, Message, Patch, SHA); everything else lowercase (adverbs, prepositions, pronouns, adjectives, "here"). Git verbs as git users know them: Checkout, Rebase, Reset, Cherry-Pick, Revert, Fetch, Pull, Push. "this Commit" names the object, "here" is the target of a move. Examples: "Checkout Commit", "Rebase main interactively onto this Commit…", "Reset main to here", "Revert Commit", "Move up", "Create annotated Tag…". Running text in hints and messages stays sentence case.

## Task intake and backlog

- The backlog is GitHub issues in this repository: one issue per independently shippable task with the problem and the desired behavior, labelled `bug` or `enhancement` and `priority: high`, `priority: medium` or `priority: low`. The coordinating session creates and updates issues with the user's approval; task briefs quote the issue and name its number. The commit that completes an issue ends its body with `Closes #<n>`. There are no pull requests yet.
- Treat feedback about the current work as steering for that work. Put unrelated requests into the backlog instead of starting them on the spot, unless the user makes them the current work.
- Keep implemented, verified and integrated distinct. A task is done once it is merged into local `main` and verified there.

## Agent coordination

- The coordinating session owns architecture, shared contracts (`GitEngine` API, the `DesignTokens` files, `ScreenshotHarness`, this file), integration into `main` and the status the user sees. It does not implement backlog tasks itself.
- Every independently scoped task runs in its own fresh linked session with its own worktree and branch `task/<short-name>` cut from local `main`. Its brief names the scope, the files it owns, dependencies, expected checks and the limits below. Follow-up feedback goes to that session; its report comes back to the coordinator.
- A task session commits on its branch only. It never merges, rebases `main`, pushes or touches another task's files. Before reporting it curates its branch into topic commits as described under Working rules (`fixup!` commits folded with `GIT_SEQUENCE_EDITOR=true git rebase -i --autosquash main`, or a regroup of its own branch; messages with context), runs `swift build`, `swift test` and the relevant harness checks, and reports the branch, its commits, the checks with their results, screenshot paths and remaining limitations.
- The coordinator reviews each reported branch (diff, build, tests, screenshots, and its commits: topics, size, messages; a branch with work-in-progress commits goes back for curation), then puts its commits directly onto local `main` with a fast-forward: no merge commits, linear history. If `main` moved meanwhile, the branch is rebased onto it first. Afterwards the branch and worktree are removed.
- Commands for the command bar (⇧⌘P) and the menu bar: title, glyph and shortcut go into `CommandCatalog` (`CommandSpec`, shortcuts in `CommandShortcut`); the controller that owns the action builds the `Command` in its `<Controller>+Commands.swift` (`CommandProvider`); `MainMenu.sections` places it in the menu bar; enabled rules go into `CommandRules` with tests.
- Harness switches of a new area go into their own `ScreenshotHarness+<Area>.swift` extension and one line each in the README's grouped list; the core `ScreenshotHarness.swift` holds only shared helpers. Preferences live in `AppSettings`; the settings window edits them.
- Task sessions do not create, edit or close issues; the coordinator keeps them.
- Never let two sessions edit the same files at the same time. Shared files are the coordinator's; a task that needs a new token namespace or harness switch adds only its own block and the coordinator resolves overlaps at integration.
- Run as many task sessions in parallel as the work allows, but each worktree builds into its own `.build`, so keep heavy checks bounded and never run two `swift test` in one checkout.
- The repository has a private GitHub remote (`origin`). Only the coordinating session pushes, and only `main` with the user's approval; task sessions never push. There are no pull requests yet: task branches are fast-forwarded onto local `main` as described above.
