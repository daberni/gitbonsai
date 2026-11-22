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
- `Sources/GitBonsaiApp` — the app (`swift run GitBonsaiApp <repo>`): `DesignTokens.swift` mirrors `docs/design/tokens.json`, `GraphRowView` draws a history row, `SidebarView` the five-column sidebar grid, `DetailView` the selection panel. Check UI changes with the screenshot harness (see README) in light and dark.
- `Tests/` — XCTest. Fixture repos are built on the fly with `git` in a temp dir (see `GitEngineTests/FixtureRepo.swift`).
- `docs/` — product and architecture docs, design language.
- `scripts/` — fixture and benchmark helpers.

## Working rules

- Build with `swift build`; test with `swift test`. Both must pass before a commit.
- Keep `GitEngine` and `GraphLayout` free of AppKit/SwiftUI imports.
- Run every `git` with `GIT_TERMINAL_PROMPT=0`, `-c core.quotepath=off`, `-c color.ui=never`; reads additionally with `GIT_OPTIONAL_LOCKS=0`.
- Parsers get a fixture test for every format they consume, including: unicode paths, renames, submodules, conflicts, detached HEAD, octopus merges, empty repo.
- Performance budgets are tests (`swift test --filter Performance`): first 300 commits laid out in < 100 ms; 100k commits laid out in < 2 s on Apple Silicon.
- Comments explain intent or constraints, never mechanics. Prefer complete statements over line-length wrapping.
- Commit messages: imperative subject, body only when needed.
