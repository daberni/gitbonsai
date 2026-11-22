# Git operations

Which git command each operation in the app runs. Every call goes through `GitRunner` with `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`, `-c core.quotepath=off` and `-c color.ui=never`; reads also get `GIT_OPTIONAL_LOCKS=0`. Writes run one at a time per working tree, whichever runner or tab starts them. Reads that compare the working tree with the index (marked "Index queue") wait in the same queue: `git diff` rewrites stale stat information under `index.lock` and ignores `GIT_OPTIONAL_LOCKS`, which made concurrent checkouts fail.

Keep this file in step with `Sources/GitEngine`: a change that adds or changes a git call updates its row here.

## Opening and loading

| Operation | Git command | Notes |
|---|---|---|
| Open a folder as repository | `git rev-parse --path-format=absolute --show-toplevel --git-common-dir` | Finds the worktree root and the shared `.git` |
| History | `git log <format> --branches --remotes --tags [HEAD]` plus the stash commits | Streamed; tool refs and other worktrees' HEADs stay out |
| Commit count | `git rev-list --branches --remotes --tags [HEAD] --count` | |
| Refs for labels and sidebar | `git for-each-ref <format>` | |
| Working directory status | `git status --porcelain=v2 -z --branch --untracked-files=all` | |
| Worktrees | `git worktree list --porcelain -z` | |
| Faster history on large repositories | `git commit-graph write --reachable` | Write |

## Commits and files

| Operation | Git command | Notes |
|---|---|---|
| Files of a commit | `git diff --name-status -M -z <parent> <commit>`; root commit `git diff-tree -r --root --no-commit-id --name-status -M -z <commit>` | Plus `--numstat` for the counts |
| Diff of a file in a commit | `git diff -p --no-color --no-ext-diff -M <parent> <commit> -- <paths>` | Full file view adds `--unified=<max>` |
| Diff of unstaged / staged changes | `git diff -p … -- <paths>` / `git diff --cached -p … -- <paths>` | Unstaged: index queue |
| Diff of an untracked file | `git diff --no-index -p … -- /dev/null <path>` | |
| Counts in the file lists | `git diff [--cached] --numstat -M -z` | Without `--cached`: index queue |
| Open in the external diff tool | `git difftool --no-prompt [-M <base> <commit> \| --cached] -- <paths>` | |
| Restore a file from a commit | `git restore --source=<commit> --worktree -- <path>` | Asks first when local changes would be overwritten |
| Save a commit as patch | `git format-patch -1 --stdout <commit>` | |

## Staging and committing

| Operation | Git command | Notes |
|---|---|---|
| Stage files | `git add -- <paths>` | |
| Unstage files | `git restore --staged -- <paths>`; before the first commit `git rm --cached -q -- <paths>` | |
| Stage / unstage a hunk | `git apply --cached [--reverse] --whitespace=nowarn -` | Patch of the hunk on stdin |
| Discard a hunk | `git apply --reverse --whitespace=nowarn -` | |
| Discard file changes | `git restore --worktree -- <paths>` | Asks first |
| Delete untracked files | `git clean -f -q -- <paths>` | Asks first |
| Commit / amend | `git commit --cleanup=whitespace -F - [--amend]` | Message on stdin |
| Message for amend | `git log -1 --format=%B` | |
| Signing hint | `git config --bool commit.gpgsign`, `git config gpg.format` | |
| Amend warning for pushed HEAD | `git merge-base --is-ancestor HEAD @{upstream}` | |

## Branches and checkout

| Operation | Git command | Notes |
|---|---|---|
| Check out a local branch | `git switch <branch>` | |
| Check out a remote branch without local branch | `git switch -c <branch> --track <remote>/<branch>` | |
| Check out a remote branch whose local branch is behind | `git switch <branch>`, `git merge --ff-only <remote>/<branch>` | The local branch tracks the remote one; a local branch that only has its name is checked out as it is |
| Reset a diverged local branch to its remote branch | `git switch -C <branch> <remote>/<branch>` | Asks first, naming the local commits that are lost |
| Check out a commit | `git switch --detach <commit>` | |
| Carry local changes through any checkout | `git status --porcelain -z --untracked-files=normal --ignore-submodules=all`; with changes `git stash push --include-untracked -m "GitBonsai: Änderungen beim Wechsel zu <target>"`, the switch, `git stash pop --index` (retried as `git stash pop` when git cannot restore the index) | `git rev-parse --verify --quiet refs/stash` before and after the push tells whether a stash was made. A failed switch pops at once; a conflicting pop keeps the stash and lists `git diff --name-only -z --diff-filter=U` (index queue) |
| New branch | `git switch -c <name> <start>` or `git branch <name> <start>`; in a new worktree `git worktree add -b <name> <path> <start>` | From a remote branch git sets it as upstream (`branch.autoSetupMerge`) |
| Validate a new branch name | `git check-ref-format --branch <name>` | Live while typing; valid only when git returns the name unchanged, so shorthands like `@{-1}` are refused. Existing names are checked against the loaded local branches |
| Start points for the ref picker | `git for-each-ref --format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(subject)%1f%(*objectname)%1f%(*committerdate:unix)%1f%(*subject)%1e refs/heads refs/remotes refs/tags` | Annotated tags peeled to their commit; remote `HEAD` and tags of trees or blobs left out |
| HEAD and a typed SHA in the ref picker | `git log -1 --format=%H%x1f%ct%x1f%s --end-of-options <revision>^{commit} --` | For HEAD when the sheet opens, and for a query of 4 to 40 hex digits |
| Rename | `git branch -m <old> <new>` | |
| Set / unset upstream | `git branch --set-upstream-to=<upstream> <branch>` / `git branch --unset-upstream <branch>` | |
| Delete | `git branch -d <branch>`; `-D` after asking | |
| Delete on the remote | `git push <remote> --delete <branch>` | Asks first |
| Merge into the current branch | `git merge --no-edit <ref>` | Conflicts are listed with `git diff --name-only -z --diff-filter=U` (index queue) |
| Reset the current branch | `git reset --soft\|--mixed\|--hard <commit>` | |

## History rewriting

| Operation | Git command | Notes |
|---|---|---|
| Rebase the current branch onto a commit | `git rebase --empty=drop <commit>` | Counts published commits with `git merge-base HEAD @{upstream}` and `git rev-list --count` for a hint in the status line; no question. Commits already on the base ("skipped previously applied commit", "-- patch contents already upstream") are counted in a toast |
| Rebase with --onto | `git rebase --empty=drop --onto <new base> <old base> <branch>` | As above. Only when the one-click rebase from a detected base cannot run as a todo list |
| Detect the old base of a rebase | `git rev-list ^<target> <branch>`, `git for-each-ref --format=%(objectname)%00%(refname:short) refs/heads`, `git log --walk-reflogs --format=%H%x00%gD --branches`, `git rev-list --count <candidate>..<branch>` | Rule 1, stacked branch: the own commit nearest to the tip that another local branch points at or pointed at per its reflog; equally near candidates on both sides of a merge are a tie and open the sheet. Runs while the menu is open and names the result in the one-click entry; the interactive entry starts its sheet from the same result |
| | `git merge-base <target> <branch>`, `git rev-list --first-parent --reverse ^<target> <branch>`, `git log -p --no-merges --no-ext-diff --no-textconv --max-count=500 <merge base>..<target>`, `git diff --no-ext-diff --no-textconv <merge base> <commit>`, `git patch-id --stable` (diffs on stdin) | Rule 2, squash-merged parent: the longest run of the branch's oldest commits (at most 50, never all of them) whose combined diff has the patch-id of a target commit |
| | `git merge-base --fork-point <target branch> <branch>` | Rule 3, rewritten target: only for a row with a local or remote branch, and only when the fork point is one of the branch's own commits. Otherwise the range starts at `git merge-base <target> HEAD` |
| Continue / skip / abort | `git rebase\|cherry-pick\|revert\|merge --continue\|--skip\|--abort` | Continue and skip with `GIT_EDITOR=true`; a merge has no `--skip`. Continue at a conflict stop first checks `git ls-files --unmerged` and `git diff --cached --quiet HEAD`; a step resolved to exactly HEAD runs `--skip` instead. While an interactive rebase of the app runs, `git -c commit.cleanup=whitespace rebase --continue\|--skip` with its message script as `GIT_EDITOR`; abort also removes the app's session folder |
| Operation in progress | `git rev-parse --path-format=absolute --git-path rebase-merge …` | Rebase, cherry-pick, revert or merge (`MERGE_HEAD`); banner above the history. The last line of `rebase-merge/done` and the `amend` marker tell an `edit` stop from a conflict or a failed `exec` |
| Commits of an interactive rebase | `git merge-base --is-ancestor <base> HEAD`, `git log --reverse --format=%H%x1f%P%x1f%s%x1f%B%x1e <base>..HEAD` | Refused when the base is not in HEAD's history or a merge is in the range |
| Stacked branches in the range | `git for-each-ref --format=%(objectname)%00%(refname)%00%(worktreepath) refs/heads` | Branches checked out in a worktree are left out |
| Interactive rebase | `git -c commit.cleanup=whitespace rebase --interactive --no-autosquash --empty=drop --update-refs\|--no-update-refs --autostash\|--no-autostash <base>` | Reads `rev-parse HEAD` and `symbolic-ref -q HEAD` first. `GIT_SEQUENCE_EDITOR` and `GIT_EDITOR` are scripts in `git rev-parse --git-path gitbonsai-rebase` that write the app's todo list and its prepared messages; no editor opens |
| Interactive rebase onto any commit | same as interactive rebase, with `--onto <target> <old base>`; in place (`<base>` alone) when `git merge-base --is-ancestor <target> HEAD` | The old base comes from the detection above and can be changed in the sheet. Commits are `git log --reverse --topo-order --no-merges <old base>..HEAD` (merges flattened, counted with `git rev-list --count --merges`); `git cherry <target> HEAD <old base>` marks commits the target already has, which start as drop. The sheet loads base and target with `git log -1 --format=… <commit>`. The one-click "Rebase … auf …" runs the same plan with every commit picked, so the status line can undo it |
| Reword, drop, move up, move down | same as interactive rebase, from `<commit>^` (move down: `<commit>^^`) | One-step todo lists; resolved with `git rev-parse --verify` |
| Undo an interactive rebase | `git reset --keep <ORIG_HEAD>`, `git update-ref --stdin` | Only while HEAD, its branch and `ORIG_HEAD` are where the rebase left them; stacked branches go back in one transaction |
| Cherry-pick | `git cherry-pick [--empty=drop] [-m 1] <commit>` | `-m 1` for merges; `--empty=drop` from git 2.45 on, read once per binary with `git --version` |
| Revert | `git revert --no-edit [-m 1] <commit>` | |

## Tags and stashes

| Operation | Git command | Notes |
|---|---|---|
| List tags | `git for-each-ref --sort=-creatordate <format> refs/tags` | |
| Create tag | `git tag <name> <commit>`; annotated `git tag -a <name> -F - <commit>` | |
| Delete tag | `git tag --delete <name>` | |
| Push / delete tag on a remote | `git push <remote> refs/tags/<name>` / `git push <remote> --delete refs/tags/<name>` | Delete asks first |
| Tag status per remote | `git ls-remote --tags <remote>` and `git for-each-ref --format=<name, object, peeled object> refs/tags` | Once per remote when the Tags list opens, kept until the next `fetch`, `pull` or `push` through the repository; stopped after 10 s. Tags compare by the object their ref names, so an annotated tag recreated on the same commit differs |
| Fetch one tag | `git fetch --no-tags <remote> refs/tags/<name>:refs/tags/<name>` | "Holen" for a tag only on the remote; never overwrites a differing local tag |
| List stashes | `git stash list --format=…` | |
| Stash | `git stash push [--include-untracked] [-m <message>]` | |
| Apply / pop / drop | `git stash apply\|pop\|drop <selector>` | Drop asks first |
| Branch from a stash | `git stash branch <name> <selector>` | |

## Worktrees

| Operation | Git command | Notes |
|---|---|---|
| New worktree | `git worktree add [-b <branch> \| --detach] <path> <commit>` or `git worktree add <path> <branch>` | |
| Remove | `git worktree remove [--force] <path>` | Asks first; can delete its branch too |
| Lock / unlock | `git worktree lock [--reason <text>] <path>` / `git worktree unlock <path>` | |
| Prune | `git worktree prune` | |

## Remotes

| Operation | Git command | Notes |
|---|---|---|
| List remotes | `git remote` | |
| Fetch all | `git fetch --all --prune` | |
| Fetch one remote | `git fetch --prune\|--no-prune <remote>` | |
| Fetch tags | `git fetch --all --tags` | |
| Upstream and ahead/behind | `git config --get branch.<b>.remote`, `git config --get branch.<b>.merge`, `git rev-list --left-right --count refs/heads/<b>...<b>@{upstream}` | Counts next to Pull and Push |
| Default pull mode | `git config --type=bool-or-str --get pull.rebase`, `… --get pull.ff` | `pull.rebase` first, then `pull.ff`; without either fast-forward only |
| Pull, fast-forward only | `git pull --no-rebase --ff-only --no-autostash` | Every pull runs with `GIT_EDITOR=true` |
| Pull, merge | `git pull --no-rebase --ff --no-edit --no-autostash` | Conflicts are listed with `git diff --name-only -z --diff-filter=U` (index queue) |
| Pull, rebase | `git pull --rebase --no-autostash` | |
| Pull with autostash | `git pull <default mode flags> --autostash` | |
| Set upstream before a pull | `git branch --set-upstream-to=<remote>/<branch> <b>` | Then pulls with the default mode |
| Push to the upstream | `git push <remote> refs/heads/<b>:refs/heads/<upstream branch>` | |
| First push | `git push -u <remote> refs/heads/<b>:refs/heads/<name>` | Sets the upstream |
| Push after a non-fast-forward rejection | `git push --force-with-lease <remote> refs/heads/<b>:refs/heads/<upstream branch>` | Only after a confirmation; never `--force` |
| Push tags | `git push <remote> --tags` | |
