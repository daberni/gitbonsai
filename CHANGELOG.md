# Changelog

User-visible changes of each GitBonsai release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- The Remove Worktree sheet shows the worktree and the “Also delete branch” checkbox on their own lines, and the message box of the Squash sheet opens at its first line with an inset, growing with the message before it scrolls.

## [0.2.0] - 2026-11-26

### Added

- Undo from the status line after amending, dropping a commit, deleting a tag or removing a remote; these local actions run without asking first.
- Conflicted files can be acted on directly, all changes discarded at once, and branches without an upstream pushed.
- A stash shows its staged and unstaged changes, and every row in the detail panel links to its parent.
- The detail panel's title line shows the SHA with a copy button and the parent links; edit and discard sit next to the texts they act on.
- The Tags popover filters with a switch in its title line.
- Every disabled context menu entry says why it is disabled.

### Changed

- Context menus reworked: actions per branch, tag, remote and worktree, safer defaults. Rebase leaves out commits that are already on the base when the base is unambiguous, and removing a worktree replaces pruning.
- The app fetches every time it becomes active (switching back within a few seconds does not fetch again) instead of every five minutes.
- After popping or applying a stash the working directory is selected.
- The co-author menu is gone from the commit form.
- Opening a repository is faster: the history starts off the main thread and shows a full first screen at once.
- Hunk buttons stay in view while scrolling, and disabled ones say why.
- The file list's section actions look and behave like links.

### Fixed

- The history stays in place after a fetch.
- The command bar opens below the banner when the history column shows a diff or the conflict view.
- A diff that cannot be read shows an error with Retry.
- Go to Ref shows refs that point at the same commit as one row.
- A tab moves off a worktree that was removed outside the app.
- Hover in lists stays on the row under the pointer while scrolling; diagonal scrolling keeps history and diff rows aligned.
- Reads and writes hold up against unusual git configuration, odd paths and concurrent changes.

## [0.1.1] - 2026-11-24

### Added

- **Squash Commits…** for several selected commits.
- Fast-forward another local branch to HEAD from its menu.

### Changed

- Ref and commit menus are ordered by group, and refs are drawn in one pill style everywhere.
- Go to Parent and Go to Child left the commit context menu; ⌘↓ and ⌘↑ remain.

### Fixed

- A layout loop when sizing commit message bodies.
- The rebase menu keeps its shape while it is open.
- The history row menu opens without the system outline around rows.

## [0.1.0] - 2026-11-24

First release: a native macOS Git client around the commit graph, with history, diff, staging and committing, branches, remotes, tags, stashes and worktrees, all running the `git` command line tool.

[Unreleased]: https://github.com/daberni/gitbonsai/compare/0.2.0...HEAD
[0.2.0]: https://github.com/daberni/gitbonsai/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/daberni/gitbonsai/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/daberni/gitbonsai/releases/tag/0.1.0
