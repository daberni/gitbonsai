# GitBonsai — Flows

See also: [Feature overview](feature-overview.md) · [Architecture](architecture.md) · [Screens](screens.md) · [Git operations](git-operations.md)

Each flow names its steps, the git commands they run and the feedback in the app. All commands run with the environment from [Architecture › GitRunner](architecture.md#2-gitrunner); [git-operations.md](git-operations.md) is the complete list. The status line under the history shows the command of the last action and its duration.

## 1. Open a repository

1. Open a folder with ⌘O, from Open Recent, from the empty tab's list of recent repositories and repository folders, or as a command-line argument. `git rev-parse --path-format=absolute --show-toplevel --git-common-dir` finds the worktree root and the shared `.git`. A subfolder of a repository opens the repository.
2. Side by side: `git for-each-ref` fills the sidebar and the ref pills, `git status --porcelain=v2 -z --branch --untracked-files=all` the working directory row, `git worktree list --porcelain -z` the worktrees, and `git log` streams the history (see [Architecture › History pipeline](architecture.md#5-history-pipeline)).
3. The file watcher starts. From then on the tab is reconciled whenever it becomes visible, the app becomes active or its files change.
4. With automatic fetching on (Settings › Fetching), the visible tab fetches on activation and periodically.

Errors: a folder outside any repository shows a failure sheet with git's message. Without a path the app restores the tabs of the last session.

## 2. Clone

1. File › Clone Repository… (⌥⌘N) or "Clone…" on the empty tab. The sheet takes the URL (a URL on the clipboard is suggested), the parent folder, an optional branch, "recurse submodules" and "shallow".
2. `git clone --progress [--recurse-submodules] [--depth 1] [--branch <branch>] -- <url> <folder>`; progress comes from stderr. Cancelling stops git and removes the folder.
3. The clone opens in a new tab.

Errors: git never prompts, so credentials must come from the credential helper or the SSH agent; a failure shows the complete git output.

## 3. Stage and commit

1. Select the working directory row in the history. The detail panel lists unstaged and staged files with their line counts.
2. Stage or unstage a file with its row button or the file's context menu (`git add -- <paths>`, `git restore --staged -- <paths>`); Repository › Stage all changes and Unstage all changes do the same for every file. Discarding asks first (`git restore --worktree`, untracked files `git clean -f`).
3. Click a file to open its diff in the history column. Each hunk has Stage or Unstage and Discard; the patch of the hunk goes to `git apply --cached [--reverse] -` on stdin.
4. Type the subject and body in the commit form. "Amend" loads the last message (`git log -1 --format=%B`) and warns when HEAD is already on its upstream.
5. Commit with the button or ⌘↩: `git commit --cleanup=whitespace -F - [--amend]`, message on stdin. The new commit appears at the top of the history and the form clears.

Errors: a rejecting hook or failed signing shows the complete git output and keeps the message. Not implemented: prefilling from `commit.template` and ⌘⇧↩ for amend (backlog: "Commit template and amend shortcut"), staging single lines.

## 4. Fetch, pull, push

1. **Fetch** (⇧⌘F): `git fetch --all --prune`. The Fetch button's menu also offers each remote with and without prune and `git fetch --all --tags`. Every fetch ends with the tab's in-place refresh, so new commits enter the history.
2. **Pull** (⇧⌘L): the default mode comes from `pull.rebase`, then `pull.ff`, and is fast-forward only without either. The Pull button's menu offers fast-forward only, merge and rebase. Every pull runs with `--autostash`, so local changes are carried along; when applying them again conflicts, a toast with "Show conflicts" and the status line say so and the stash stays.
3. **Push** (⇧⌘U): `git push <remote> refs/heads/<branch>:refs/heads/<upstream branch>`. Without an upstream a sheet asks for remote and name and pushes with `-u`. A non-fast-forward rejection offers `--force-with-lease` after asking; plain `--force` is never used.
4. Badges on Pull and Push show the behind and ahead counts against the upstream; a branch without upstream shows a marker on Push.

Errors: git's complete output in the failure sheet; a diverged branch on pull asks how to go on.

## 5. Create and check out branches

1. Branch › New Branch… (⌘B), the toolbar's Branch button, the plus on the sidebar's Local header, or "Create Branch…" in a commit's menu. The sheet takes the name (validated live with `git check-ref-format --branch`), a start point from the ref picker, "check out" and "in a new worktree".
2. Creating runs `git branch <name> <start>`, `git switch -c <name> <start>` or `git worktree add -b <name> <path> <start>`.
3. Checking out: double-click a branch in the sidebar, Branch › Checkout Branch… or a menu. A local branch is `git switch <branch>`; a remote branch without local branch `git switch -c <branch> --track <remote>/<branch>`; a commit `git switch --detach <commit>`, which shows a HEAD pill in the history.
4. A remote branch that a local branch tracks checks out the local branch and fast-forwards it (`git merge --ff-only`). If they diverged, the app asks, naming the local commits that would be lost: reset to the remote branch (`git switch -C`), check out as it is, or cancel.
5. Every checkout carries local changes: with changes it runs `git stash push --include-untracked -m "GitBonsai: …"`, the switch, then `git stash pop --index`.

Errors: a failed switch pops the stash at once; a conflicting pop keeps the stash and lists the conflicts. A branch checked out in another worktree moves the tab to that worktree instead.

## 6. Merge, cherry-pick, revert, reset

1. A branch's context menu (sidebar or ref pill) offers merging it into the current branch: `git merge --no-edit <ref>`.
2. A commit's context menu offers Cherry-Pick (`git cherry-pick [--empty=drop] [-m 1] <commit>`), Revert Commit (`git revert --no-edit [-m 1] <commit>`) and Reset to here (`--soft`, `--mixed`, `--hard`).
3. When local changes block a cherry-pick, revert, merge or rebase, the failure offers to stash them and retry; the stash is popped afterwards.
4. A stop on conflicts shows the operation banner above the history with Continue, Skip and Abort (`git <operation> --continue|--skip|--abort`) and lists the conflicting files in the working directory. Resolve them in an editor, stage them, then continue.

Not implemented: merge or rebase by drag and drop with a preview, taking ours or theirs per file, and a conflict editor; see the backlog.

## 7. Stash and pop

1. **Stash** (⇧⌘S or the toolbar) runs at once, without a dialog: `git stash push --include-untracked -m "WIP on <branch>: <subject>"`. A toast offers Undo while the stash is the newest and nothing changed since.
2. The Stash button's menu offers "Stash with Message…" and "Stash staged changes only" (`--staged`).
3. **Pop** (⌥⇧⌘S or the toolbar) pops the newest stash. The sidebar's Stashes row opens a popover with all stashes: show the diff, apply, pop, drop (asks first) or create a branch from it.

Errors: a conflicting pop keeps the stash and shows the conflicts.

## 8. Worktrees

1. Create one from a commit's menu ("Create Worktree…"), a branch's menu, or the new-branch sheet with "in a new worktree": `git worktree add [-b <branch> | --detach] <path> <commit>` or `git worktree add <path> <branch>`.
2. Switch with a double-click on the worktree in the sidebar or Branch › Switch Worktree…: the tab moves to that worktree with its own runner, status and watcher. The history stays, because the repository is shared; the working directory row and HEAD follow.
3. The worktree's context menu opens it in Finder or the terminal, locks or unlocks it, removes it (asks first and offers to delete its branch) and prunes missing worktrees.

Not implemented: the plus on the Worktrees header (backlog: "Create a worktree from the sidebar's `+`").

## 9. Interactive rebase

Preconditions: no merge between base and HEAD, otherwise the entry is disabled with the reason in its tooltip.

1. "Rebase <branch> interactively onto this Commit…" in a commit's menu, or Branch › Interactive Rebase…. On an ancestor of HEAD the branch is rewritten in place; otherwise the branch's own commits from the detected base move onto it (`--onto`), and the base can be changed at the top of the sheet. Commits the target already has start as drop.
2. The sheet lists the commits with pick, reword, edit, squash, fixup and drop as popups or the keys p, r, e, s, f, d, reorders by dragging or ⌥↑/⌥↓, edits messages for reword and squash groups, and shows the result as a small graph with the stacked branches that move along. Options: "update refs" (`--update-refs`) and "autostash".
3. Start writes the todo list and prepared messages into `git rev-parse --git-path gitbonsai-rebase` and runs `git -c commit.cleanup=whitespace rebase --interactive --no-autosquash --empty=drop … <base>`. `GIT_SEQUENCE_EDITOR` and `GIT_EDITOR` are scripts that write the app's list and messages; no editor opens, also when continuing after a stop or a restart of the app.
4. A stop shows the banner with step n of m: at `edit` with "Amend Commit…", at a failed `exec` with the command, at conflicts with their number; plus Continue, Skip and Abort.
5. Single steps in a commit's menu (Move up, Move down, Drop Commit…) run the same machinery from the commit below. "Edit Message" (commit menu, Repository › Edit Commit Message, double-click on the subject, the pencil in the detail panel, or ⌘E) edits subject and body in place in the detail panel; ⌘↩ saves, Esc cancels. HEAD alone is amended with `git commit --amend --only`; older commits take the one-step rebase.
6. After a rebase the status line offers Undo while HEAD, its branch and `ORIG_HEAD` are where the rebase left them: `git reset --keep <ORIG_HEAD>`, with moved stacked branches restored in one `git update-ref --stdin` transaction.

Errors: commits already on the base are dropped and counted in a toast; rewriting published commits shows a quiet hint instead of a question; dropping every commit asks first.

## 10. Search commits

1. Edit › Search Commits (⌘F) focuses the search field above the history. Typing searches the loaded commits in memory: subject, body, author name and email, ref names and SHA prefixes of 4 or more characters, without running git.
2. Non-matching rows are dimmed, the field shows the match count, ↩ and ⇧↩ jump to the next and previous match, Esc clears the search.

Not implemented: filters by path or date and content search (`git log -S/-G`).

## 11. Compare commits

1. ⌘-click a second history row. Two commits show `git diff <older> <newer>` in the detail panel's file list and the diff view; when they sit on different branches, a switch compares "since common base" (`<older>...<newer>`).
2. A run of consecutive commits shows their combined change; commits with gaps are listed one below the other like `git show`.

## Not implemented

Drag and drop of branches and commits with a preview, a conflict editor, a reflog browser, file history and blame. Planned items are in the project backlog.
