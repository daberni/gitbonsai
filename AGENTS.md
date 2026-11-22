# GitBonsai — agent instructions

GitBonsai is a native macOS Git client (SwiftUI + AppKit) with a graph-centric UX. Every Git operation runs through the native `git` binary; nothing is reimplemented that git itself provides.

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
  - Shared: `DesignTokens.swift` mirrors `docs/design/tokens.json`, `Glyphs`, `ChromeViews`. `ScreenshotHarness` holds all verification switches.
  - When a type starts mixing responsibilities or passes about 300 lines, split it before adding more.
  - Minimum is macOS 26. A SwiftPM build records the minimum as its SDK version, and AppKit draws the current window style (larger traffic lights, Liquid Glass controls) only for SDK 26 and later. An Xcode-built app bundle records the real SDK; revisit the minimum once the app is packaged that way.
  - No literal sizes, spacings, radii, strokes, fonts or alphas in views. Use the scales in `Theme` (`Space`, `Radius`, `Stroke`, `Icon`, `Wash`, fonts), which mirror `docs/design/tokens.json`; sizes that belong to one component go into its namespace in `DesignTokens.swift` (`Theme.Tabs`, `Theme.Sidebar`, …). Check a refactor of numbers with before/after screenshots: they must be pixel-identical apart from times.
- `Tests/` — XCTest. Fixture repos are built on the fly with `git` in a temp dir (see `GitEngineTests/FixtureRepo.swift`).
- `docs/` — product and architecture docs, design language.
- `scripts/` — fixture and benchmark helpers.

## Working rules

- Build with `swift build`; test with `swift test`. Both must pass before a commit. The build stays free of compiler warnings, in debug and release (`swift build -c release`); a change fixes the warnings it introduces.
- Keep `GitEngine` and `GraphLayout` free of AppKit/SwiftUI imports.
- Run every `git` with `GIT_TERMINAL_PROMPT=0`, `-c core.quotepath=off`, `-c color.ui=never`; reads additionally with `GIT_OPTIONAL_LOCKS=0`.
- Parsers get a fixture test for every format they consume, including: unicode paths, renames, submodules, conflicts, detached HEAD, octopus merges, empty repo.
- Performance budgets are tests (`swift test --filter Performance`): first 300 commits laid out in < 100 ms; 100k commits laid out in < 2 s on Apple Silicon.
- Comments explain intent or constraints, never mechanics. Prefer complete statements over line-length wrapping.
- Commit messages: imperative subject, body only when needed.
- [docs/git-operations.md](docs/git-operations.md) lists the git command behind every operation. A change that adds or changes a git call updates its rows there in the same commit.

## Code and architecture conventions

- Develop against the current state. Internal APIs, view types and module structure change together; update every caller in the same change instead of keeping old signatures, aliases or fallback paths for earlier versions.
- Keep types focused on one reason to change. A view draws or lays out one coherent part; a controller owns one interaction or use case; `GitEngine` owns every git call and parse. Split by responsibility instead of growing single files.
- Add behavior tests against real repositories for consequential logic: parsing, staging and patch building, history and layout rules, anything that rewrites refs or the index. Show the failure on the original defect when adding a regression test. Do not test drawing, trivial delegation or logging.
- Link-like clickable text and bare icons show the pointing hand through `LinkButton` or `LinkCursor`; bordered buttons, toolbar buttons, segmented controls, menus and table rows keep the arrow, as in native macOS apps.
- Verify UI changes in the running app through `ScreenshotHarness`, in light and dark. Interactions are checked with real mouse events through the window (see the click and drag switches in the README), not by calling the handler directly. Harness runs stay in the background; `GITBONSAI_FOREGROUND=1` is for a single check that cannot work otherwise, never for loops or batches, and only after telling the coordinator why.

## Task intake and backlog

- There are no GitHub issues or pull requests yet. The backlog is kept outside the repository by the coordinating session (until it moves to GitHub issues): one entry per independently shippable task with the problem, the desired behavior and its state. Task briefs quote the entries they need; the backlog's location is given in the brief when a session must read it.
- Treat feedback about the current work as steering for that work. Put unrelated requests into the backlog instead of starting them on the spot, unless the user makes them the current work.
- Keep implemented, verified and integrated distinct. A task is done once it is merged into local `main` and verified there.

## Agent coordination

- The coordinating session owns architecture, shared contracts (`GitEngine` API, `DesignTokens.swift`, `ScreenshotHarness`, this file), integration into `main` and the status the user sees. It does not implement backlog tasks itself.
- Every independently scoped task runs in its own fresh linked session with its own worktree and branch `task/<short-name>` cut from local `main`. Its brief names the scope, the files it owns, dependencies, expected checks and the limits below. Follow-up feedback goes to that session; its report comes back to the coordinator.
- A task session commits on its branch only. It never merges, rebases `main`, pushes or touches another task's files. Before reporting it rebases its branch onto the current local `main`, runs `swift build`, `swift test` and the relevant harness checks, and reports the branch, its commits, the checks with their results, screenshot paths and remaining limitations.
- The coordinator reviews each reported branch (diff, build, tests, screenshots), then puts its commits directly onto local `main` with a fast-forward: no merge commits, linear history. If `main` moved meanwhile, the branch is rebased onto it first. Afterwards the branch and worktree are removed.
- Harness switches of a new area go into their own `ScreenshotHarness+<Area>.swift` extension and one line each in the README's grouped list; the core `ScreenshotHarness.swift` holds only shared helpers. Preferences live in `AppSettings`; the settings window edits them.
- Task sessions do not edit the backlog; the coordinator keeps it.
- Never let two sessions edit the same files at the same time. Shared files are the coordinator's; a task that needs a new token namespace or harness switch adds only its own block and the coordinator resolves overlaps at integration.
- Run as many task sessions in parallel as the work allows, but each worktree builds into its own `.build`, so keep heavy checks bounded and never run two `swift test` in one checkout.
- Nothing is pushed. There is no remote yet.
