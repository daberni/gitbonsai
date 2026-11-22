# GitBonsai — Feature overview

See also: [Architecture](architecture.md) · [Screens](screens.md) · [Flows](flows.md) · [Design](design/README.md)

A native macOS git client with a graph-centric UX, built in AppKit on top of the plain `git` binary.

## 1. Goals and principles

- **Graph-centric UX**: the commit graph in the middle with the working directory as its first row, a detail panel on the right that follows the selection, a sidebar on the left with worktrees, tags, local branches, stashes and remotes.
- **Everything through the git CLI.** Nothing is reimplemented that git itself provides. The app visualizes and drives `git`; each action shows its git command in the status line. Parts that are not git: the graph layout, file watching, avatars.
- **No AI features, no embedded terminal, no cloud.** Only "Open in Terminal/Editor/Finder".
- **Worktrees are first class**: each worktree with its branch, tracking state and changes visible at the top of the sidebar.
- **Fast on large repositories**: the history is streamed and laid out incrementally, the table is virtualized, nothing waits for the full log.

## 2. Features

State: **✓** implemented, **planned** (in the project backlog), **–** not planned.

### 2.1 Repository and worktrees

| Feature | State |
|---|---|
| Open repositories, recent repositories, a tab per repository, session restore | ✓ |
| Repository folders: the empty tab lists the repositories found in chosen folders | ✓ |
| Clone (HTTPS/SSH, progress, cancel, branch, submodules, shallow) | ✓ |
| Worktrees: list with branch, ahead/behind and changes; switch, lock, remove, prune | ✓ |
| Create worktrees from a commit, a branch or the new-branch sheet | ✓ |
| Create a worktree from the sidebar's plus | planned |
| Open in Terminal / Editor / Finder, with detected apps | ✓ |
| Editor per repository | planned |
| Submodules, Git LFS, `git init` | – (not yet in the backlog) |

### 2.2 History

| Feature | State |
|---|---|
| Streamed, incremental lane layout, virtualized table | ✓ |
| Working directory row, stash nodes, ref pills with local and remote glyphs, detached HEAD pill | ✓ |
| Search over the loaded commits (subject, body, author, refs, SHA prefix) | ✓ |
| Search by path, date or content (`-S`/`-G`) | – (not yet in the backlog) |
| Compare two commits, a run of commits or commits with gaps | ✓ |
| Commit, ref pill, branch, tag, stash, worktree and file context menus | ✓ |
| Author avatars from the remote host or Gravatar | ✓ |
| Hide branches and folders | planned |
| Drag and drop of branches and commits with a preview | planned (design in [design-language.md](design/design-language.md#drag-and-drop)) |

### 2.3 Working directory and diff

| Feature | State |
|---|---|
| Unstaged and staged lists with line counts, keyboard navigation | ✓ |
| Stage, unstage, discard files and hunks | ✓ |
| Commit, amend, signing hint, amend warning for pushed HEAD | ✓ |
| Commit template, amend shortcut | planned |
| Unified diff, full-file view, hunk navigation, invisible characters | ✓ |
| Ignore whitespace, word diff, image diff, Markdown preview | planned |
| File history and blame | planned |
| External diff tool | ✓ |
| Staging single lines, side-by-side diff, syntax highlighting | – (not yet in the backlog) |

### 2.4 Branches, tags, remotes

| Feature | State |
|---|---|
| Create, rename, delete, check out branches; upstream; ahead/behind | ✓ |
| Fetch (all, one remote, prune, tags), automatic fetch | ✓ |
| Pull (fast-forward only, merge, rebase; always `--autostash`), pull a branch that is not checked out | ✓ |
| Push with upstream on the first push, `--force-with-lease` after asking | ✓ |
| Tags: popover, create (light and annotated), push, delete locally or on a remote, status per remote | ✓ |
| Add and edit remotes | planned |
| Connect hosting services (pull requests, CI status) | planned |

### 2.5 Merge, rebase, stash

| Feature | State |
|---|---|
| Merge, cherry-pick, revert, reset | ✓ |
| Operation banner with continue, skip, abort | ✓ |
| Rebase onto a commit with a detected base, stacked branches with `--update-refs` | ✓ |
| Interactive rebase sheet with single-step forms, in-place message editing and undo | ✓ |
| Stash, stash with message, staged only, undo, pop, apply, drop, branch from stash | ✓ |
| Stash local changes and retry a refused command | ✓ |
| Take ours or theirs per file, conflict editor | planned |
| Reflog browser | – |

### 2.6 App

| Feature | State |
|---|---|
| Settings: git binary, editors and terminals, repository folders, appearance, language, fetching, avatars | ✓ |
| Command bar (⇧⌘P) and a menu bar built from the same commands | ✓ |
| Localization: English and German | ✓ |
| Failure sheets with the complete git output | ✓ |
| Command log panel | planned |
| Themes beyond light and dark | planned |
| Signing, notarization, auto-update | planned |

## 3. Stack

AppKit throughout: the history, diff, sidebar and command bar need virtualized views drawn with CoreGraphics. A spike that rebuilds the settings window in SwiftUI is under review; forms and the welcome page are the next candidates if it is adopted. `GitEngine`, `GraphLayout` and `Avatars` are plain Swift packages without UI imports. See [architecture.md](architecture.md).

## 4. Main risks

1. **Graph rendering**: correctness and smoothness on large repositories. Budgets are tests (see [Architecture › Performance](architecture.md#8-performance)).
2. **git output as an API**: version differences (Apple git and Homebrew git), user configuration that changes formats. Neutralizing `-c` options and machine formats only; minimum version 2.38 for `--update-refs`.
3. **Credential prompts**: any prompt would hang an operation, so `GIT_TERMINAL_PROMPT=0` throughout; credentials come from the credential helper or the SSH agent.
4. **Conflicts**: resolving them still happens in an editor; a conflict editor is the largest open piece.

## 5. Competition

| Product | Backend | Relevance |
|---|---|---|
| Fork | git CLI, Cocoa | Functionally closest; UI and graph visualization are the gap |
| Tower | git CLI, native | Strong workflows and undo; subscription |
| GitUp | libgit2 | Fast graph, development has stalled |
| Sourcetree | git CLI | Dated and slow |

## 6. Name

**GitBonsai**: shaping a tree over years. Pruning is squash, drop and interactive rebase; wiring is rebase onto; grafting is cherry-pick; removing deadwood is prune; the bowl is the repository and the trunk is `main`. Tone: calm, patient, crafted; no AI buttons, no noise. Icon: a small tree in a flat bowl whose branches are graph lanes with commits (see [app-icon/README.md](design/app-icon/README.md)).

Public projects with the same name, none of them git clients: a profile SVG generator, a pixel-art profile and a branch clean-up CLI.
