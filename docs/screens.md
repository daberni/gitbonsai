# GitBonsai — Screens

See also: [Feature overview](feature-overview.md) · [Architecture](architecture.md) · [Flows](flows.md) · Design: [design language](design/design-language.md)

Shortcuts follow macOS conventions (⌘ Command, ⌥ Option, ⇧ Shift, ⌃ Control). Items marked *planned* are not built; the project backlog tracks them.

## 0. Design decisions

These decisions take precedence over anything below that reads differently; the [design language](design/design-language.md) has the details.

- **Diffs open in the history column.** Selecting a file (in a commit or the working directory) replaces the history with its diff; hunk staging happens there. The detail panel never holds a diff.
- **The detail panel has no switcher.** It follows the selection in the history: commit, working directory, comparison or stash.
- **Author and committer** are shown apart when name, email or date differ, otherwise as one line. The commit SHA copies on click; parent SHAs navigate.
- **Sidebar grid**: expander, icon, text, value, status. Only hierarchy sits on the left; the checked-out branch's check mark and the worktree glyph sit on the right.
- **Working directory row**: icons with counts, no text, not bold.
- **Wording**: no explanatory sentences in panels; no gardening vocabulary in the interface.

## 1. Main window

One window with a tab per repository. The tabs sit in the title bar next to the traffic lights; the toolbar below belongs to the active tab's repository. The tab title is the repository name; worktree and branch show in the sidebar. Three columns: sidebar (resizable, can be hidden with ⌃⌘S), history (flexible) and detail panel (resizable, can be hidden with ⌥⌘I). Window frame and panel widths are restored.

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●  [ gitbonsai ]  [ sample-app ]  [ + ]                                           │
│ Fetch   Pull ²   Push ¹   Branch   Stash   Pop                         ⌕ Search       │
├──────────────┬───────────────────────────────────────────┬───────────────────────────┤
│ WORKTREES    │ LABEL      GRAPH  COMMIT        AUTHOR DATE│ a1b2c3f ⧉                 │
│  gitbonsai ✓ │                 ◌   ✎3 ✓1 +2              │ Fix worktree status       │
│  …-feature   │ (✓ main)───────○   Fix worktree status    │ Alex Example · 2 h ago    │
│ Tags      23 │ (feature/x)────│○  Incremental layout     │ Parent f4e5d6             │
│ LOCAL      3 │                 ○│  Stream log parser     │                           │
│  Stashes   2 │ (v0.1.0)───────○╯  Scaffold package       │ Changed files (3)         │
│  main  ↑1 ↓2 │                 ○   Initial commit         │  M Sources/Status.swift   │
│  feature/    │                                           │  A Tests/StatusTests.swift │
│ ORIGIN     3 │                                           │                           │
├──────────────┴───────────────────────────────────────────┴───────────────────────────┤
│ git fetch --all --prune · 412 ms                                                       │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Toolbar

| Element | Action | Shortcut | States |
|---|---|---|---|
| Fetch | Split button: fetch all remotes (`git fetch --all --prune`); menu: each remote with and without prune, tags | ⇧⌘F | Disabled without a remote |
| Pull | Split button: the default mode from `pull.rebase`/`pull.ff`; menu: fast-forward only, merge, rebase; every pull carries local changes (`--autostash`) | ⇧⌘L | Badge with the behind count, hidden at 0; tooltip names the upstream |
| Push | Split button: push the current branch to its upstream; menu: push tags | ⇧⌘U | Badge with the ahead count; without upstream a marker, and the first push asks for remote and name. Badges never move the button |
| Branch | New branch sheet | ⌘B | – |
| Stash / Pop | Stash runs at once (`git stash push --include-untracked`); menu: with message, staged changes only. Pop pops the newest stash | ⇧⌘S / ⌥⇧⌘S | Toast with Undo after a stash; Stash disabled without changes, Pop without a stash |
| Search | Search the loaded commits | ⌘F | Match count, ↩ / ⇧↩ next and previous, Esc clears |

### 1.2 Sidebar

Sections collapse; headers carry a chevron, a glyph, the title and a count, and where something can be created, a plus (Local: new branch). Every entry has a context menu.

| Section | Content | Notes |
|---|---|---|
| Worktrees (always first) | Bonsai glyph by state, folder name, branch, ahead/behind, number of changed files; the active worktree is marked | Double-click moves the tab to the worktree. The header's plus is *planned* |
| Tags (one row with count) | No list in the sidebar | Opens a searchable popover with a switch in its title line (All, Local only, Remote only, Diverging): jump to the commit, check out, push, delete locally or on a remote, copy the name; marks which remotes have each tag |
| Local | First rows **Working Directory** (selects the working directory) and **Stashes** with count (popover: selector, message, branch, age; show, apply, pop, drop, branch from stash), then local branches grouped by prefix with ahead/behind | Double-click checks out |
| One section per remote | Remote branches grouped by prefix | Branch context menu: check out, merge, rebase onto, pull, delete on the remote. An "Add Remote…" row follows the last remote; adding and editing remotes is *planned* |

### 1.3 History

- Columns: labels, graph, commit (subject), author with avatar, SHA, date (relative, absolute in the tooltip). Columns can be resized and hidden; the graph column scrolls sideways when it is narrower than the lanes.
- Row 0 is the **working directory row** when the working tree has changes: a dashed node with counts of modified, staged and untracked files.
- Stashes are dashed square nodes linked to the commit they were made on.
- Ref pills sit right-aligned in the label column: a local branch and its remote branches of the same name share a pill, with a location glyph (check mark when checked out here, worktree glyph when checked out in another worktree, laptop otherwise) and a cloud per remote. Tags have their own pills; a detached HEAD shows a HEAD pill. Cut-off pills expand on hover or a click on "+n". Each pill has its own context menu.
- Selection: click, ↑↓, ⌘-click for a second commit to compare, ⇧-click for a run.
- Context menus of commits, ref pills and sidebar branches share one order of groups: go there (Checkout, Checkout Commit) | sync (Pull, Push, Push Tag to a remote) | integrate (Fast-Forward, Merge, Rebase, Cherry-Pick, Reset to here with soft, mixed, hard, Revert Commit) | remove (Delete, Delete Branches…, Drop Commit…) | create (Branch, Worktree, Tag, annotated Tag) | change (Rename, Upstream, Edit Message, Move up, Move down) | copy and export (Copy with the name, tag or SHA as a pill, Save Patch…). A row with several pills leads with one submenu per pill. Rebasing the current branch onto a branch has a submenu when there is more than one variant: all commits, only the branch's own commits (detected base), interactively. A remote branch that shares a pill with its local branch keeps a submenu only for what the local entries do not cover; Copy then lists the local and remote names. Entries that do not apply to a row are left out or disabled. Worktree menus follow the same order (Switch, Show in Finder, Open in terminal | Remove… | Lock…) with Prune missing Worktrees last on its own, since it acts on all worktrees; stash menus too (Show Diff | Apply Stash, Pop | Drop… | Create Branch from Stash… | Copy SHA on the history row). The remote menu keeps Edit Remote… | Remove Remote…, so a two-entry menu does not lead with the destructive entry.

### 1.4 Detail panel

Follows the selection:

- **Commit**: SHA with copy button and parents as links right below the panel title, subject and body (editable in place with ⌘E or a double-click on the subject; ⌘↩ saves, Esc cancels), author and committer with dates, changed files with line counts. A file opens its diff in the history column.
- **Working directory**: the parent link to HEAD in the same place as a commit's, unstaged and staged files with counts, stage, unstage and discard buttons on hover, ↑↓ through both lists; below them the commit form with subject, body, Amend and the commit button (⌘↩).
- **Comparison**: the files changed between the selected commits; for two commits on different branches a switch "since common base".
- **Stash**: its files split like the working directory it came from: unstaged (working tree changes and the untracked files of `stash -u`) and staged (the index); its one parent is the commit it was made on. Its index and untracked helper commits never show in the history.

File context menu: open, show in Finder, open in the external diff tool, restore from this commit, copy path; in the working directory stage, unstage and discard. File history and blame are *planned*.

### 1.5 Diff

Replaces the history while open. Header with change letter, path and a close button; a "Diff | File" toggle (the whole newer file with the changes marked in place), hunk navigation, an options menu with invisible characters. In the working directory each hunk has Stage or Unstage and Discard (asks first). Binary files show their size and encoding hints. Side-by-side view, word diff, ignoring whitespace and image diffs are *planned*.

### 1.6 Operation banner

Above the history while a rebase, cherry-pick, revert or merge is in progress: step n of m, the number of conflicts, at an `edit` stop "Amend Commit…", and Continue, Skip (not for a merge) and Abort. Conflicting files are listed in the working directory.

### 1.7 Status line

Under the history: the commit, lane and stash counts with the load time, the git command of the last action with its duration, hints such as published commits rewritten, and Undo after an interactive rebase. A panel with the whole command log is *planned*.

## 2. Empty tab, opening and cloning

A new tab (⌘T) or a launch without repositories shows recently used repositories and the repositories found in the folders listed in Settings, with a search field; ↑↓ and ↩ open, ⌘↩ opens in a new tab. Buttons: Open… (⌘O, accepts a subfolder of a repository) and Clone… (⌥⌘N).

Clone sheet: URL (a URL on the clipboard is suggested), parent folder, branch, "recurse submodules", "shallow". Progress comes from `--progress`; cancelling removes the folder. Failures show the complete git output.

## 3. Settings (⌘,)

| Section | Content |
|---|---|
| General | Repository folders for the empty tab; language (system, English, German) |
| Apps | Editors and terminals: detected apps and added ones, checked when the command bar offers them; the default carries a pill and is chosen in its row (on hover, from the context menu or as a VoiceOver action) |
| Git | The git binary (automatic or chosen) with its version; a warning below 2.38 |
| Appearance | System, light or dark appearance |
| Fetching | Automatic fetch on activation and periodically, with its interval |
| Avatars | One choice: Initials only, From the remote host, or Remote host and Gravatar, with one line on what leaves the machine; the pane keeps its height. Initials only draws plain initials, loads nothing and deletes the caches. A picture found once shows in every repository; authors without one get initials on a tint from their address. Signed-out GitHub only maps addresses in public repositories, so private ones show pictures for noreply addresses only |

## 4. Interactive rebase

A sheet opened from a commit's menu or Branch › Interactive Rebase…. Columns like the history (resizable). The commit list from old to new with an action popup per row (pick, reword, edit, squash, fixup, drop), drag handles and ⌥↑/⌥↓, the message editor for reword and squash groups, the old base at the top when rebasing onto another commit, options "update refs" and "autostash", and on the right the result as a small graph. Start runs the rebase; a stop switches to the operation banner. See [Flows › Interactive rebase](flows.md#9-interactive-rebase).

## 5. Command bar (⇧⌘P)

A floating panel centered under the toolbar: a search field and up to ten rows. Each row shows a glyph, the title with highlighted matches, a muted context (branch, remote, repository, editor) and the shortcut, if any.

- Typing filters fuzzily over titles and keywords; every word must match, word starts count more. Recently used commands come first.
- ↑↓ select, ↩ runs, Esc or a click outside closes.
- Commands with an argument open a second list in the same panel (Checkout Branch…, Switch to tab…, Open in editor with…, Open in terminal with…, Switch Worktree…, Interactive Rebase…); ⌫ in the empty field goes back.
- What cannot run now stays in the list, greyed and below the others, with the reason instead of the context ("No remote", "Nothing staged", "No stash").
- An empty tab offers only the window's commands (tabs, open, clone, settings).
- Go to Ref… (⇧⌘O) lists every branch, remote branch, tag, worktree and stash with its kind's glyph, its name as a pill in its strand's colour, the short SHA and the worktree's branch or stash message. Matches rank by name; a name typed in full or its last segment (`login` for `feature/login`) comes first. ↩ selects the commit in the history and shows the branch or worktree in the sidebar (expanding its section and folder); ⌥↩ checks the branch or tag out or switches to the worktree.

## 6. Shortcuts

The menu bar (GitBonsai, File, Edit, View, Repository, Branch, Window, Help) is built from the same commands as the command bar (`CommandCatalog`, `MainMenu`): same titles, shortcuts and enabled rules. `MainMenuTests` checks this table against the menu bar the app builds.

| Shortcut | Command |
|---|---|
| ⌘, | Settings… |
| ⌘T / ⌘W | New tab / Close tab (⌘W closes the settings and other auxiliary windows) |
| ⇧⌘T | Reopen closed tab |
| ⌘O / ⌥⌘N | Open Repository… / Clone Repository… |
| ⇧⌘] / ⇧⌘[ | Next tab / Previous tab |
| ⇧⌘P | Command bar… |
| ⇧⌘O | Go to Ref… |
| ⌘F | Search Commits |
| ⌃⌘S / ⌥⌘I | Hide sidebar / Hide detail panel |
| ⇧⌘F | Fetch all Remotes |
| ⇧⌘L / ⇧⌘U | Pull / Push |
| ⇧⌘S / ⌥⇧⌘S | Stash changes / Pop Stash |
| ⌘↩ | Commit… |
| ⌘E | Edit Commit Message |
| ⌘B | New Branch… |
| ⌥⌘T / ⇧⌘E / ⇧⌘R | Open in terminal / Open in editor / Show in Finder |

Inside views: ↑↓ move through the history and the file lists, ⌘-click and ⇧-click select several commits, ⌥↑/⌥↓ and p, r, e, s, f, d in the interactive rebase sheet. Shortcuts for staging and file actions are *planned*.
