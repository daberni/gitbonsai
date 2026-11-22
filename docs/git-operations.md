# Git operations

Which git command each operation in the app runs. Every call goes through `GitRunner` with `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`, `-c core.quotepath=off` and `-c color.ui=never`; reads also get `GIT_OPTIONAL_LOCKS=0`. Writes run one at a time per runner.

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
| Diff of unstaged / staged changes | `git diff -p … -- <paths>` / `git diff --cached -p … -- <paths>` | |
| Diff of an untracked file | `git diff --no-index -p … -- /dev/null <path>` | |
| Counts in the file lists | `git diff [--cached] --numstat -M -z` | |
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
| Check out a remote branch | `git switch -c <branch> --track <remote>/<branch>`; if the local branch exists `git switch <branch>` | Being changed: fast-forward or reset the local branch |
| Check out a commit | `git switch --detach <commit>` | |
| Check out carrying local changes | `git stash push --include-untracked -m "GitBonsai: Wechsel"`, the switch, `git stash pop` | A failed switch restores with `git stash pop --index` |
| New branch | `git switch -c <name> <start>` or `git branch <name> <start>` | |
| Rename | `git branch -m <old> <new>` | |
| Set / unset upstream | `git branch --set-upstream-to=<upstream> <branch>` / `git branch --unset-upstream <branch>` | |
| Delete | `git branch -d <branch>`; `-D` after asking | |
| Delete on the remote | `git push <remote> --delete <branch>` | Asks first |
| Merge into the current branch | `git merge --no-edit <ref>` | Conflicts are listed with `git diff --name-only -z --diff-filter=U` |
| Reset the current branch | `git reset --soft\|--mixed\|--hard <commit>` | |

## History rewriting

| Operation | Git command | Notes |
|---|---|---|
| Rebase the current branch onto a commit | `git rebase <commit>` | Counts published commits with `git merge-base HEAD @{upstream}` and `git rev-list --count` |
| Rebase with --onto | `git rebase --onto <new base> <old base> <branch>` | |
| Continue / skip / abort | `git rebase\|cherry-pick\|revert --continue\|--skip\|--abort` | Continue and skip with `GIT_EDITOR=true` |
| Operation in progress | `git rev-parse --path-format=absolute --git-path rebase-merge …` | Banner above the history |
| Cherry-pick | `git cherry-pick [-m 1] <commit>` | `-m 1` for merges |
| Revert | `git revert --no-edit [-m 1] <commit>` | |

## Tags and stashes

| Operation | Git command | Notes |
|---|---|---|
| List tags | `git for-each-ref --sort=-creatordate <format> refs/tags` | |
| Create tag | `git tag <name> <commit>`; annotated `git tag -a <name> -F - <commit>` | |
| Delete tag | `git tag --delete <name>` | |
| Push / delete tag on a remote | `git push <remote> refs/tags/<name>` / `git push <remote> --delete refs/tags/<name>` | Delete asks first |
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
| Pull, push | | Being built |
