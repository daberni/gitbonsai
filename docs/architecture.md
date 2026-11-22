# GitBonsai — Architecture

See also: [Feature overview](feature-overview.md) · [Screens](screens.md) · [Flows](flows.md) · [Git operations](git-operations.md)

## 1. Layers

| Layer | Target | Depends on | Responsibility |
|---|---|---|---|
| Engine | `GitEngine` | Foundation | Process runner, models, parsers, the `Repository` facade, file watching, command rules, commit search |
| Layout | `GraphLayout` | `GitEngine` | Incremental lane layout of the commit graph, row diffs for in-place refreshes; pure functions over `Commit` values |
| Avatars | `Avatars` | Foundation | Author avatars from the remote host (GitHub, GitLab) or Gravatar, with memory and disk caches |
| App | `GitBonsaiApp` | all three, AppKit | Windows and tabs, history, diff, sidebar, sheets, settings, command bar, and `ScreenshotHarness` for verification |

Rules: `GitEngine`, `GraphLayout` and `Avatars` import neither AppKit nor SwiftUI. Every repository read and write is a `git` command run by `GitRunner`; nothing is reimplemented that git itself provides. [git-operations.md](git-operations.md) lists the command behind every operation.

The app is AppKit with SwiftUI for self-contained forms and panels; section 1.1 states the rule.

### 1.1 AppKit and SwiftUI

Decided after the settings spike (`docs/spikes/settings-swiftui.md`).

**AppKit** for the main window and everything inside it: window, tab row in the title bar, toolbar, sidebar, history table and graph, detail panel and file lists, diff and conflict views, popovers with custom rows, the command bar and the interactive rebase sheet. These need custom CoreGraphics drawing, virtualized lists of up to 100k rows, precise focus, key and click handling, and the harness's real-event driving. The main window is expected to stay AppKit.

**SwiftUI**, hosted in AppKit through `NSHostingController`, for self-contained forms and panels that are mostly standard controls: the settings window today; candidates are the welcome page, form sheets (clone, new branch, failure) and future side panels.

Rules for SwiftUI surfaces:
- The window, its lifecycle and its toolbar stay AppKit; SwiftUI fills the content (the app starts through `main.swift` and `AppDelegate`, so SwiftUI scenes are not used).
- State goes through a small `@Observable` model that reads and writes the existing stores (`AppSettings`, controllers); no second copy of state.
- Design tokens come from `DesignTokens+SwiftUI.swift`; no literal sizes or colours, as in AppKit.
- Text is `LocalizedStringResource("key", defaultValue: "…", bundle: .module, comment: …)` with semantic keys.
- Every interactive control has an accessibility identifier, so `ScreenshotHarness` can find and click it through the accessibility tree.
- Content-sized windows measure the form (`onScrollGeometryChange`) and cap the height.

Never mix the two inside one surface beyond a hosted view; a SwiftUI view per commit or per list row in the main window is ruled out.

## 2. GitRunner

`GitRunner` is an actor per repository path. Each worktree gets its own runner, because `git -C <worktree>` decides the working tree.

### 2.1 Environment

| Variable / option | Reads | Writes | Purpose |
|---|---|---|---|
| `GIT_TERMINAL_PROMPT=0` | ✅ | ✅ | No hang on credential or passphrase prompts; credentials come from the credential helper or the SSH agent |
| `GIT_OPTIONAL_LOCKS=0` | ✅ | – | `status` and `log` take no optional index locks, so reads do not disturb writes |
| `LC_ALL=C` | ✅ | ✅ | Stable English messages that error matching can rely on |
| `-c core.quotepath=off` | ✅ | ✅ | Unicode paths unescaped |
| `-c color.ui=never` | ✅ | ✅ | No ANSI sequences in parsed output |
| `-c log.showSignature=false` | ✅ | ✅ | No signature output in `log` |

The git binary is `GIT_BONSAI_GIT` if set, else the one chosen in Settings › Git, else the first of `/opt/homebrew/bin/git`, `/usr/local/bin/git`, `/usr/bin/git`. Aliases are never used; every command is a built-in git command with its full name.

### 2.2 Concurrency

- **Reads** (`run`, `stream`) run concurrently.
- **Writes** (`runWrite`) run one at a time per working tree through `IndexLockQueue`, whichever runner or tab starts them.
- **Index-refreshing reads** (`runRefreshingIndex`): `git diff` against the working tree rewrites stale stat information under `index.lock` and ignores `GIT_OPTIONAL_LOCKS`, so these reads wait in the same queue as writes.
- **Streams**: `stream(_:)` yields stdout chunks as `AsyncThrowingStream<Data, Error>`. Cancelling the consuming task terminates git; a non-zero exit ends the stream with `GitError` carrying the full stderr.
- **Timeouts**: none, except the remote tag status, which gives up after 10 s.

### 2.3 Command log

Every invocation is recorded as a `GitCommandLogEntry` (arguments, exit code, duration, stderr), the last 500 per runner. The app shows the command of each action and its duration in the status line under the history; a panel that lists the whole log is planned (backlog: "Command log").

## 3. Formats

Parsers consume machine formats only, and each has fixture tests against real repositories built in the tests.

| Data | Command | Parser |
|---|---|---|
| History | `git log --format=<fields separated by 0x1F, record end 0x1E> [--topo-order] --branches --remotes --tags [HEAD]` plus the stash commits | `LogParser`, incremental per chunk; fields are hash, parents, author name, email and date, committer name, email and date, subject, body |
| Refs | `git for-each-ref --format=…` | `RefsParser`, `RefTipsParser` |
| Status | `git status --porcelain=v2 -z --branch --untracked-files=all` | `StatusParser` (ordinary, renamed, unmerged and untracked entries, branch headers) |
| Diff | `git diff -p --no-color --no-ext-diff -M …` | `DiffParser`, hunks with lines and "No newline at end of file" |
| Worktrees | `git worktree list --porcelain -z` | `WorktreeParser` |

Hunk staging sends the file header and one hunk to `git apply --cached [--reverse] --whitespace=nowarn -` on stdin; discarding a hunk uses `git apply --reverse`. The interactive rebase writes its own todo list through `GIT_SEQUENCE_EDITOR` and its prepared messages through `GIT_EDITOR`, both small scripts in `git rev-parse --git-path gitbonsai-rebase` (see [Flows › Interactive rebase](flows.md#9-interactive-rebase)).

## 4. File watching and refresh

- **Sources**: `RepositoryWatcher` runs FSEvents on the working tree and the common git directory, found with `git rev-parse --absolute-git-dir`. `WatchScope` ignores objects, lock files, reflogs other than the stash, and folders such as `node_modules` and `.build`.
- **Bursts**: events are gathered until 0.2 s pass without a relevant event, and for 1 s at most after the first one, so a long build cannot hold changes back.
- **Own writes**: a burst that falls inside one of the app's own writes (`WriteActivity`), or within 0.5 s after it, is dropped; the write refreshes the tab itself.
- **Reconcile**: a tab is reconciled when it becomes visible, when the app becomes active, after a burst and after every fetch. `TabReconciler` and `RefreshCoalescer` gather triggers that arrive together into one refresh. The refresh reads status, refs, stashes and worktrees side by side and runs `git log` only for commits that are not loaded yet; `HistoryRowDiff` applies the difference to the shown rows instead of reloading the table.
- Only the visible tab is reconciled; hidden tabs catch up when they become visible.

## 5. History pipeline

```
git log (stream) ─▶ LogParser.feed ─▶ GraphLayout ─▶ LogLoader batches ─▶ GraphViewModel (main actor)
                                                                                  │
                                                               NSTableView (virtualized, HistoryViewController)
                                                                                  │
                                                               GraphRowView draws lanes, nodes and labels with CoreGraphics
```

1. `Repository` streams `git log`; `LogParser` yields `Commit` values as soon as a record is complete.
2. `GraphLayout` keeps only the active lanes and returns a row per commit with its lane, colour and edges to the next row. Memory per row is constant. A lane keeps its colour from fork to merge.
3. `LogLoader` hands rows over in batches: the first at once, later ones after 500 commits or 100 ms. The table inserts them and asks only for visible rows.
4. `GraphRowView` draws lanes, edges, nodes, ref pills and text directly. There is never one view per commit.
5. Refs, avatars and worktree HEADs come from separate queries and are merged into the rows by commit.
6. The working directory row is a synthetic first row with HEAD as parent; it appears only when `git status` reports changes. Stashes appear as nodes on the commit they were made on.

There is no on-disk cache: every open streams the history from git.

## 6. Concurrency model

| Level | Isolation | Content |
|---|---|---|
| `GitRunner` | actor per worktree path | Processes, command log |
| `IndexLockQueue` | one per resolved working tree, process-wide | Order of writes and index-refreshing reads |
| `Repository` | `Sendable` facade | Starts commands on its runner, returns values and streams |
| `RepositoryWatcher` | own dispatch queue | FSEvents and bursts |
| `GraphViewModel` and controllers | `@MainActor` | Loaded history, status, refs and worktrees of a tab; the controllers own one interaction each |
| Views | main actor | AppKit |

Operations are `Task`s; streams are cancelled when a tab closes or switches worktree.

## 7. Errors

- `GitError` carries the arguments, the exit code and the full stderr.
- A failed action shows a failure sheet with a short sentence and the complete git output behind "Git Output". Known cases get actions: conflicts show the operation banner and the conflicting files; local changes that block a cherry-pick, revert, merge or rebase offer to stash them and retry; a non-fast-forward push offers `--force-with-lease` after asking.
- A failure is never silent: the status line shows the failed command.

## 8. Performance

Budgets that are tests (`swift test --filter Performance`):

| Measure | Test |
|---|---|
| `GraphLayout` over 100k synthetic commits | `GraphLayoutTests.testPerformanceHundredThousandCommits`, under 3 s |
| Commit search over 100k commits | `CommitSearchTests.testPerformanceHundredThousandCommits` |

`scripts/make-synthetic-repo.sh <folder> 100000` creates a 100k-commit repository with branches and merges for checks by hand in the app.

## 9. Verification

UI work is verified in the running app, without a human, through `ScreenshotHarness`:

- `GITBONSAI_SCREENSHOT=<png> swift run GitBonsaiApp <repo>` renders the window to a PNG once loading has finished and quits. Harness runs stay in the background, keep their session in their own defaults domain (`app.gitbonsai.harness`) and never fetch or load avatars unless asked.
- Further `GITBONSAI_*` switches drive the app with real mouse and key events through the window (clicks, drags, menus, sheets, the command bar) and print its state as text: the history, the selection, menus with their enabled state, toolbar badges, the status line. The README lists every switch by area.
- Each area's switches live in their own `ScreenshotHarness+<Area>.swift` extension; `ScreenshotHarness.swift` holds the shared helpers.
- Engine and layout logic is covered by XCTest against fixture repositories that `Tests/GitEngineTests/FixtureRepo.swift` builds with git in a temporary folder.
