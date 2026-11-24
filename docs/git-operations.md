# Git operations

Which git command each operation in the app runs. Every call goes through `GitRunner` with `GIT_TERMINAL_PROMPT=0`, `LC_ALL=C`, `-c core.quotepath=off` and `-c color.ui=never`; reads also get `GIT_OPTIONAL_LOCKS=0`. Inherited `GIT_*` variables are removed, so a hook or parent git that exported `GIT_DIR`, `GIT_INDEX_FILE` or author dates cannot redirect the app's git; transport, credential, config-file and trace variables (`GIT_SSH_COMMAND`, `GIT_ASKPASS`, `GIT_CONFIG_GLOBAL`, `GIT_TRACE*` …) stay. Writes run one at a time per working tree, whichever runner or tab starts them. Reads that compare the working tree with the index (marked "Index queue") wait in the same queue: `git diff` rewrites stale stat information under `index.lock` and ignores `GIT_OPTIONAL_LOCKS`, which made concurrent checkouts fail. Commands that only change refs or the remote (fetch, push, tag push and remote deletes, marked "outside the queue") do not wait in it, so a slow remote never holds up staging.

git runs in its own process group. Cancelling an action stops git and what it started (ssh, helpers, hooks) with SIGTERM, then SIGKILL after 2 s, and an action still waiting in the queue leaves it without running. The command log keeps the last 500 commands with the first 16 KB of their output.

Keep this file in step with `Sources/GitEngine`: a change that adds or changes a git call updates its row here.

## Opening and loading

| Operation | Git command | Notes |
|---|---|---|
| Open a folder as repository | `git rev-parse --path-format=absolute --show-toplevel --git-common-dir` | Finds the worktree root and the shared `.git` |
| History | `git log <format> <order> --branches --remotes --tags [HEAD]` plus the stash commits | `<order>` is the setting "History order": `--date-order` (Date, default), `--author-date-order` (Author date) or `--topo-order` (Branches together); changing it reads the history again. Streamed; tool refs and other worktrees' HEADs stay out. `HEAD` only when `git rev-parse --verify --quiet HEAD` finds it, so a repository without commits loads empty. `<format>` ends with `%(trailers:only,unfold)`, git's trailer parser (the same as `git interpret-trailers --parse`), for co-authors and the trailer block in the detail panel and for the search |
| Refs for labels and sidebar | `git for-each-ref <format> refs/heads refs/remotes refs/tags refs/stash` | Tool namespaces such as `refs/codex/…` stay out; tags of trees or blobs are dropped (`%(*objecttype)`), since as history tips they would force a full reload on every refresh. `%(upstream:track)` gives every local branch its ahead and behind counts for the sidebar in the same call |
| Commit-graph for a fast first page of history | `git config --type=bool --get core.commitGraph`, `git config --type=bool --get gc.writeCommitGraph`, `git rev-parse --path-format=absolute --git-path objects/info/commit-graph --git-path objects/info/commit-graphs/commit-graph-chain --git-path index.lock`, then `git commit-graph write --reachable` | Once per tab, in the background after the first load, only when neither graph file exists. Without the graph `git log` in any of the orders walks the whole history before printing anything (0.45 s on 100k commits), with it the first commits stream at once. Skipped when either setting is false or an `index.lock` shows another git operation at work; git takes its own `commit-graph.lock`, and a failure is ignored. Afterwards git's own `gc`, `maintenance` and `fetch.writeCommitGraph` keep the file current |
| Working directory status | `git status --porcelain=v2 -z --branch --untracked-files=all` | |
| Worktrees | `git worktree list --porcelain -z` | |
| Reconcile a tab (it becomes visible, the app becomes active, its files change, after every fetch) | The in-place refresh: working directory status, `git for-each-ref`, the stash list and `git worktree list` side by side; `git log` only when a ref, HEAD or stash points at a commit that is not loaded; when commits left the history, `git rev-list <order> --branches --remotes --tags [HEAD]` plus the stash commits for the new order of the rest; `git rev-parse --git-common-dir` for the time of the last fetch (`FETCH_HEAD`), which a fetch in a terminal moves; afterwards `git remote` for the fetch menu and the toolbar, the pull and push state, and the avatar service's remotes again | Visible tab only, local only, never skipped; triggers that arrive together run once. A remote counts for the toolbar once it is configured, before anything was fetched |
| Watch a tab's files | `git rev-parse --absolute-git-dir`, then FSEvents on the working tree and the common git directory | No git while watching. Objects, lock files, reflogs other than the stash and folders such as `node_modules` and `.build` are ignored; a burst ends after 0.2 s of quiet or 1 s at most; bursts inside the app's own writes are dropped; an index-refreshing read only hides bursts that touched nothing but the index, so an edit made meanwhile still counts. `.git/config` counts, so `git remote add` in a terminal reconciles the tab |
| Clone | `git clone --progress [--recurse-submodules] [--depth 1] [--branch <branch>] -- <url> <folder>` | Progress read from stderr; cancelling stops git and removes the folder; no prompts, so credentials come from the credential helper or the SSH agent |
| Repositories in the repository folders | none | Found on disk by their `.git` folder or file, without git |
| Remote for avatars | `git config -z --get-regexp ^remote\..*\.url$` and `git for-each-ref --format=%(HEAD)%00%(upstream:remotename) refs/heads` | Once per tab while avatars are on, and again after every reconcile, replacing the service only when it changed; the upstream remote of the current branch, else `origin`, else the first one, decides the avatar service |

## Commits and files

| Operation | Git command | Notes |
|---|---|---|
| Files of a commit | `git diff --name-status -M -z <parent> <commit>`; root commit `git diff-tree -r --root --no-commit-id --name-status -M -z <commit>` | Plus `--numstat` for the counts |
| Diff of a file in a commit | `git diff -p --no-color --no-ext-diff -M --src-prefix=a/ --dst-prefix=b/ <parent> <commit> -- <paths>` | Full file view adds `--unified=<max>`. The explicit prefixes override `diff.noprefix` and `diff.mnemonicPrefix`, which would break parsing and `git apply`; every `git diff -p …` below carries them |
| Compare two selected commits | `git merge-base <older> <newer>`; files `git diff --name-status -M -z <older> <newer>` plus `--numstat`; with "since common base" `<merge base>` in place of `<older>`, the same as `<older>...<newer>` | The switch only shows when the merge base is not `<older>`, that is when the commits sit on different branches |
| Compare a run of selected commits | Files `git diff --name-status -M -z <oldest>^ <newest>` plus `--numstat`; a root commit starts at the empty tree (`git hash-object -t tree /dev/null`) | Whether the commits follow one another on one first-parent line is read from the loaded parents, without git |
| Compare selected commits with gaps | Files of each commit as for one commit, listed one below the other like `git show <commits>` | |
| Diff of a file in a comparison | `git diff -p --no-color --no-ext-diff -M <base> <target> -- <paths>` | Full file view adds `--unified=<max>` |
| Diff of unstaged / staged changes | `git diff -p … -- <paths>` / `git diff --cached -p … -- <paths>` | Unstaged: index queue |
| Diff of an untracked file | `git diff --no-index -p … -- /dev/null <path>` | Not when `git ls-files --cached -z -- <path>` lists it: a file in the index is no longer untracked |
| Diff options: whitespace and word diff | Every diff read above adds `-w --ignore-cr-at-eol` (Ignore Whitespace) or `-b --ignore-cr-at-eol` (Ignore Whitespace amount), and `--ignore-blank-lines`; Word Diff reads the same diff once more with `--word-diff=porcelain` (in the full file view the full file read carries it) | When git prints nothing under these options, the read without them tells "only whitespace changed" from no changes. Hunks read this way do not match the file, so hunk stage and discard are disabled while any of them is on; the hunks git applies always come from the diff without `--word-diff` |
| Encoding of a binary diff | `git cat-file -s <rev>:<path>`, then `git cat-file blob <rev>:<path>` up to 16 MB; the index as `:<path>`; working tree and untracked files are read directly | Only for files git shows as binary; a UTF-16 or UTF-32 byte order mark or NUL pattern names the encoding and the `working-tree-encoding` hint |
| Images of a changed image file | Per side `git cat-file -s <rev>:<path>`, then `git cat-file blob <rev>:<path>`; old side: first parent, comparison base, `HEAD` (staged) or the index `:<old path>` (unstaged); new side: the commit, comparison target or index `:<path>` (staged); unstaged and untracked files are read from the working tree | Only for png, jpg, gif, webp, heic, tiff, bmp, svg and pdf. A side over 32 MB loads on a click. No smudge filter runs, so an LFS file reads as its pointer and the text diff stays with a note |
| Counts in the file lists | `git diff [--cached] --numstat -M -z` | Without `--cached`: index queue. A newly shown working directory list waits up to 150 ms so names and counts appear together |
| Open in the external diff tool | `git difftool --no-prompt [-M <base> <commit> \| -M <base> <target> \| --cached -M] -- <paths>`; untracked `git difftool --no-prompt --no-index -- /dev/null <path>` | `<base> <target>` for a file of a comparison. Offered once `git config --get diff.tool`, `diff.guitool` or `merge.tool` names a tool |
| Restore files from a commit | `git restore --source=<commit> --worktree -- <paths>`, one call per source revision | `git cat-file -e <commit>:<path>`, else the same for the first parent, picks each file's source. Asks first when `git status --porcelain=v2 -z --untracked-files=all --ignored=matching -- <paths>` shows local changes that would be overwritten |
| Revert a commit's changes to files | `git diff --binary -M <parent> <commit> -- <paths>`, then `git apply --reverse --whitespace=nowarn -` | Working tree only; a root commit is compared against the empty tree (`git hash-object -t tree /dev/null`). Renamed files pass their old path too. git applies the whole patch or nothing |
| Save a commit as patch | `git format-patch -1 --stdout --src-prefix=a/ --dst-prefix=b/ <commit>` | |

## Staging and committing

| Operation | Git command | Notes |
|---|---|---|
| Stage files | `git add -- <paths>` | |
| Unstage files | `git restore --staged -- <paths>`; before the first commit `git rm --cached -q -- <paths>` | `git rev-parse --verify --quiet HEAD` tells whether there is a commit |
| Stage / unstage a hunk | `git apply --cached [--reverse] --whitespace=nowarn -` | Patch of the hunk on stdin, built from the diff's raw bytes so files that are not UTF-8 apply |
| Discard a hunk | `git apply --reverse --whitespace=nowarn -` | |
| Discard file changes | `git restore --worktree -- <paths>` | Asks first. The command bar's "Discard all changes…" passes every tracked file with unstaged changes; staged changes and untracked files stay |
| Delete untracked files | `git clean -f -q -- <paths>` | Asks first |
| Commit / amend | `git commit --cleanup=whitespace -F - [--amend] [--trailer "Co-authored-by: <name> <email>" …] [--trailer "Signed-off-by: <committer>"]` | Message on stdin. ⌥⌘⏎ amends with the typed message. Trailers the message already has (`git interpret-trailers --parse`, stdin) are not passed again; the sign-off identity comes from `git var GIT_COMMITTER_IDENT` |
| Commit all changes | `git diff --name-only --diff-filter=U -z`, then `git add -A`, then the commit above without `--amend` | ⇧⌘⏎, or the button with ⇧ held ("Commit All"). Takes modified, deleted and untracked files whatever is staged. Unmerged paths refuse it before anything is staged, since `git add` would mark them resolved; during a merge it otherwise concludes the merge like `git commit -a`. A failing commit leaves everything staged |
| Commit template | `git config --path commit.template`, then the file is read | Prefills the body of an empty commit form; `#` lines are dropped, a relative path counts from the working tree |
| Co-author picker | `git shortlog -sne --all` | Loaded when the menu first opens; the mailmap applies |
| Message for amend | `git log -1 --format=%B` | |
| Signing hint | `git config --bool commit.gpgsign`, `git config gpg.format` | |
| Amend warning for pushed HEAD | `git merge-base --is-ancestor HEAD @{upstream}` | |

## Branches and checkout

| Operation | Git command | Notes |
|---|---|---|
| Check out a local branch | `git switch <branch>` | |
| Check out a remote branch without local branch | `git switch -c <branch> --track <remote>/<branch>` | `git rev-parse --verify --quiet refs/heads/<branch>` decides; an existing local branch is switched to |
| Check out a remote branch whose local branch is behind | `git symbolic-ref -q HEAD` (or `git rev-parse --verify HEAD` when detached), `git switch <branch>`, `git merge --ff-only <remote>/<branch>` | The local branch tracks the remote one; a local branch that only has its name is checked out as it is. A refused fast-forward switches back (`git switch <original>` or `git switch --detach <commit>`) before the carried changes are put back |
| Reset a diverged local branch to its remote branch | `git switch -C <branch> <remote>/<branch>` | Asks first, naming the local commits that are lost; Undo brings them back |
| Check out a commit | `git switch --detach <commit>` | |
| Carry local changes through any checkout | `git status --porcelain -z --untracked-files=normal --ignore-submodules=all`; with changes `git stash list`, `git stash push --include-untracked -m "GitBonsai: changes when switching to <target>"`, `git stash list`, `git status --porcelain --untracked-files=all`, the switch, `git stash pop --index <selector>` (retried as `git stash pop <selector>` when git cannot restore the index) | The stash list before and after the push tells whether a stash was made, and the selector is looked up by its commit before the pop. A failed switch pops at once; if that pop fails, the error names the stash that keeps the changes. A conflicting pop on the target keeps the stash and lists `git diff --name-only -z --diff-filter=U` (index queue) |
| New branch | `git switch -c <name> <start>` or `git branch <name> <start>`; in a new worktree `git worktree add -b <name> <path> <start>` | From a remote branch git sets it as upstream (`branch.autoSetupMerge`) |
| Validate a new branch name | `git check-ref-format --branch <name>` | Live while typing; valid only when git returns the name unchanged, so shorthands like `@{-1}` are refused. Existing names are checked against the loaded local branches |
| Start points and bases for the ref picker | `git for-each-ref --format=%(refname)%1f%(objectname)%1f%(committerdate:unix)%1f%(subject)%1f%(*objectname)%1f%(*committerdate:unix)%1f%(*subject)%1e refs/heads refs/remotes refs/tags` | Annotated tags peeled to their commit; remote `HEAD` and tags of trees or blobs left out |
| HEAD, suggested bases and a typed revision in the ref picker | `git log -1 --format=%H%x1f%ct%x1f%s --end-of-options <revision>^{commit} --` | For HEAD when the new-branch sheet opens, for each detected base and the merge base of the interactive rebase sheet, and for any query that is not a listed name |
| Rename | `git branch -m <old> <new>` | |
| Set / unset upstream | `git branch --set-upstream-to=<upstream> <branch>` / `git branch --unset-upstream <branch>` | |
| Delete | `git branch -d <branch>`; `-D` after asking | A merged branch goes without asking; Undo recreates it |
| Delete everywhere | `git for-each-ref --format=%(objectname)%00%(upstream:remotename)%00%(upstream:remoteref) refs/heads/<b>`, `git remote`, `git rev-parse --verify` of each `refs/remotes/<remote>/<b>` and the upstream, `git rev-list --count <sha> --not --exclude=<b> --branches --exclude=<remote>/<b> … --remotes --tags HEAD`; then `git branch -d\|-D <b>` and `git push <remote> --delete refs/heads/<name>` per remote | Asks first with every ref, its commit and whether its commits are in no other ref, one checkbox each. `-D` for an unmerged local branch, and after `-d` refuses a branch whose commits another ref holds. The local branch goes first; a remote that fails does not stop the others |
| Delete on the remote | `git push <remote> --delete refs/heads/<branch>` | Asks first; the full ref name keeps a remote tag of the same name out of it, and a branch already gone on the remote is deleted without error, which removes its stale remote-tracking ref. Outside the queue |
| Merge into the current branch | `git merge --no-edit <ref>` | On failure `git rev-parse --verify --quiet MERGE_HEAD` tells a stopped merge; its conflicts are listed with `git diff --name-only -z --diff-filter=U` (index queue) |
| Reset the current branch | `git reset --soft\|--mixed\|--hard <commit>` | Only a hard reset over uncommitted changes to tracked files asks first |
| Undo a local operation | `git switch <branch>` or `git switch --detach <sha>` after a checkout, `git reset --keep\|--soft\|--mixed <sha>` when HEAD's branch moved, then `git update-ref --stdin` for the other refs it moved | Rebase, cherry-pick, revert, merge, reset, checkout and branch deletion record HEAD (`git symbolic-ref -q HEAD`, `git rev-parse --verify`) and the refs they may move before and after; Undo in the status line is offered while all are still where the operation left them. A soft or mixed reset is undone with the same mode |
| Fast-forward the current branch: check | `git symbolic-ref -q HEAD`, `git rev-parse --verify <ref>^{commit}`, `git merge-base --is-ancestor <target> <branch head>`, `git merge-base --is-ancestor <branch head> <target>` | Only the checked-out branch is fast-forwarded; detached HEAD is refused. Refused before anything runs when the branch already contains the target or has commits of its own. The menus offer the entry only for targets that reach the branch in the loaded history |
| Fast-forward the current branch | `git merge --ff-only <ref>` | Ref by its full name (`refs/heads/…`, `refs/remotes/<remote>/<branch>`) or a commit's SHA. Commits taken with `git rev-list --count <old>..<new>` |
| Fast-forward another branch to HEAD: check | `git worktree list --porcelain`, `git rev-parse --verify HEAD^{commit}`, `git rev-parse --verify refs/heads/<b>^{commit}`, `git merge-base --is-ancestor <head> <b>`, `git merge-base --is-ancestor <b> <head>` | Only a local branch other than HEAD's, and only to HEAD. The menus offer it when the branch is a strict ancestor of HEAD in the loaded history; refused before anything runs when it already contains HEAD or has commits of its own |
| Fast-forward a branch checked out nowhere to HEAD | `git fetch --no-write-fetch-head . HEAD:refs/heads/<b>` | git refuses anything but a fast-forward. Commits taken with `git rev-list --count <old>..<new>`; the status line offers Undo |
| Fast-forward a branch checked out in another worktree to HEAD | `git -C <worktree> merge --ff-only <head sha>` | The worktree's files move with the branch; local changes in the way make git refuse, and the failure says why. No Undo, which would move the ref without the files |

## History rewriting

| Operation | Git command | Notes |
|---|---|---|
| Rebase the current branch onto a commit | `git rebase --empty=drop <commit>` | Counts published commits with `git merge-base HEAD @{upstream}` and `git rev-list --count` for a hint in the status line; no question. Commits already on the base ("skipped previously applied commit", "-- patch contents already upstream") are counted in a toast |
| Rebase with --onto | `git rebase --empty=drop --onto <new base> <old base> <branch>` | As above. Only when the one-click rebase from a detected base cannot run as a todo list |
| Detect the old base of a rebase | `git rev-list ^<target> <branch>`, `git for-each-ref --format=%(objectname)%00%(refname:short) refs/heads`, `git log --walk-reflogs --format=%H%x00%gD --branches`, `git rev-list --count <candidate>..<branch>` | Rule 1, stacked branch: the own commit nearest to the tip that another local branch points at or pointed at per its reflog; equally near candidates on both sides of a merge are a tie and open the sheet. Runs while the menu is open and names the result in the one-click entry; the interactive entry starts its sheet from the same result |
| | `git merge-base <target> <branch>`, `git rev-list --first-parent --reverse ^<target> <branch>`, `git log -p --no-merges --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --max-count=500 <merge base>..<target>`, `git diff --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ <merge base> <commit>`, `git patch-id --stable` (diffs on stdin) | Rule 2, squash-merged parent: the longest run of the branch's oldest commits (at most 50, never all of them) whose combined diff has the patch-id of a target commit |
| | `git merge-base --fork-point <target branch> <branch>` | Rule 3, rewritten target: only for a row with a local or remote branch, and only when the fork point is one of the branch's own commits. Otherwise the range starts at `git merge-base <target> HEAD` |
| Continue / skip / abort | `git rebase\|cherry-pick\|revert\|merge --continue\|--skip\|--abort` | Continue and skip with `GIT_EDITOR=true`; a merge has no `--skip`. Continue at a conflict stop first checks `git ls-files --unmerged` and `git diff --cached --quiet HEAD`; a step resolved to exactly HEAD runs `--skip` instead. While an interactive rebase of the app runs, `git -c commit.cleanup=whitespace rebase --continue\|--skip` with its message script as `GIT_EDITOR`; abort also removes the app's session folder |
| Operation in progress | `git rev-parse --path-format=absolute --git-path rebase-merge …` | Rebase, cherry-pick, revert or merge (`MERGE_HEAD`); banner above the history. The last line of `rebase-merge/done` and the `amend` marker tell an `edit` stop from a conflict or a failed `exec` |
| Commits of an interactive rebase | `git merge-base --is-ancestor <base> HEAD`, `git log --reverse --format=%H%x1f%P%x1f%s%x1f%B%x1e <base>..HEAD` | Refused when the base is not in HEAD's history or a merge is in the range |
| Stacked branches in the range | `git for-each-ref --format=%(objectname)%00%(refname)%00%(worktreepath) refs/heads` | Branches checked out in a worktree are left out |
| Interactive rebase | `git -c commit.cleanup=whitespace rebase --interactive --no-autosquash --empty=drop --update-refs\|--no-update-refs --autostash\|--no-autostash <base>` | Reads `rev-parse HEAD` and `symbolic-ref -q HEAD` first. `GIT_SEQUENCE_EDITOR` and `GIT_EDITOR` are scripts in `git rev-parse --git-path gitbonsai-rebase` that write the app's todo list and its prepared messages; no editor opens |
| Interactive rebase onto any commit | same as interactive rebase, with `--onto <target> <old base>`; in place (`<base>` alone) when `git merge-base --is-ancestor <target> HEAD` | The old base comes from the detection above and can be changed in the sheet. Commits are `git log --reverse --topo-order --no-merges <old base>..HEAD` (merges flattened, counted with `git rev-list --count --merges`); `git cherry <target> HEAD <old base>` marks commits the target already has, which start as drop. The sheet loads base and target with `git log -1 --format=… <commit>`. The one-click "Rebase … onto this Commit" runs the same plan with every commit picked, so the status line can undo it |
| Squash selected commits | `git merge-base --is-ancestor <commit> HEAD` and `git rev-list --count --first-parent <commit>..HEAD` per commit to find the oldest, then the interactive rebase from `<oldest>^` with `pick <oldest>`, `squash` for the others and `pick` for the commits above; `--autostash` when there are uncommitted changes | Refused unless the commits are consecutive on HEAD's first-parent line with no merge among or above them. git keeps the oldest commit's author; the message is the joined messages with trailers deduplicated at the end, edited in the sheet. Undone like every rebase |
| Drop, move up, move down | same as interactive rebase, from `<commit>^` (move down: `<commit>^^`) | One-step todo lists; resolved with `git rev-parse --verify` |
| Edit a commit message (reword) | HEAD alone: `git commit --amend --only --cleanup=whitespace -F -`, then `git update-ref ORIG_HEAD <old HEAD>`; otherwise the interactive rebase from `<commit>^` with a one-step todo list, `--autostash` when there are uncommitted changes | Edited in place in the detail panel. `--only` keeps staged changes staged and out of the commit; another branch on HEAD takes the rebase path so `--update-refs` moves it along. The amend leaves the same undo record as a rebase, and the rewritten commit is `HEAD~<commits above it>` afterwards |
| Undo an interactive rebase | `git reset --keep <ORIG_HEAD>`, `git update-ref --stdin` | Only while HEAD, its branch and `ORIG_HEAD` are where the rebase left them; stacked branches go back in one transaction |
| Cherry-pick | `git cherry-pick [--empty=drop] [-m 1] <commit>` | `-m 1` for merges; `--empty=drop` from git 2.45 on, read once per binary with `git --version` |
| Revert | `git revert --no-edit [-m 1] <commit>` | |

## Conflicts

| Operation | Git command | Notes |
|---|---|---|
| Diff of a conflicted file | `git diff -p --no-color --no-ext-diff -M -- <path>` (index queue) | git answers with a combined `diff --cc`, read as a diff against ours. `--numstat` lists an unmerged path twice, `0 0` first, then its count against ours |
| Stages of a conflict | `git ls-files -u -z [-- <path>]` | Which of base (1), ours (2) and theirs (3) exist tells content, delete/modify, rename and both-deleted conflicts apart |
| Three-way alignment of a text conflict | `git cat-file -s <oid>`, `git cat-file blob <oid>` per stage, then `git diff --no-index --no-color --no-ext-diff --no-textconv --text --diff-algorithm=histogram -U0 -- <base> <ours>` and the same for theirs | The stages go through a temporary folder; a missing base is an empty file. Hunks of both sides that overlap or touch form a conflict, as in git's merge; a change of one side is taken. A NUL byte in the first 8000 bytes of a side, or a side over 8 MB, means whole sides only. A side that is not valid UTF-8 is read and written as ISO Latin 1 |
| Merge simple conflicts (word merge) | `git merge-file -p -q <ours> <base> <theirs>` over token files with one word, white-space run or other character per line | Exit 0 takes the merged words; any conflict, also touching changes, leaves the conflict open |
| Mark resolved | the file is written, then `git add -- <path>` | The result comes from the sides taken or ignored per change and the word merge in the conflict view |
| Take a whole side (binary, keep a file one side deleted) | `git checkout --ours\|--theirs -- <path>`, `git add -- <path>` | |
| Delete a file one side deleted or renamed away | `git rm -q -f -- <path>` | |
| Merge tool of a repository | `git config --get merge.guitool`, then `git config --get merge.tool` | The tool `git mergetool --gui` opens. "Resolve…" opens it when the settings choose the merge tool and one is set; otherwise the merge window |
| Open in the merge tool | `git mergetool --gui --no-prompt -- <path>` | `--gui` prefers `merge.guitool`, as a terminal tool like vimdiff has no terminal in the app. Runs outside the index queue while the tool is open; git stages the result itself when the tool reports success |
| Merge tools to choose from (settings) | `git mergetool --tool-help` | Read in the C locale: tools git found, marked "requires a graphical session", and user-defined ones (`mergetool.<name>.cmd`); terminal tools are not offered |
| Choose the merge tool (settings) | `git config --global --get merge.guitool`; `git config --global merge.guitool <tool>` | Choosing GitBonsai leaves the git config as it is |

## Tags and stashes

| Operation | Git command | Notes |
|---|---|---|
| List tags | `git for-each-ref --sort=-creatordate <format> refs/tags` | Tags of trees or blobs are left out |
| Create tag | `git tag <name> <commit>`; annotated `git tag -a <name> -F - <commit>` | |
| Delete tag | `git tag --delete <name>` | |
| Push / delete tag on a remote | `git push <remote> refs/tags/<name>` / `git push <remote> --delete refs/tags/<name>` | Delete asks first. Outside the queue |
| Tag status per remote | `git ls-remote --tags <remote>` and `git for-each-ref --format=<name, object, peeled object> refs/tags` | Once per remote when the Tags list opens, kept until the next `fetch`, `pull` or `push` through the repository or until a remote's URL changes (`git config -z --get-regexp ^remote\..*\.url$` with each refresh of the list); stopped after 10 s. Tags compare by the object their ref names, so an annotated tag recreated on the same commit differs |
| Fetch one tag | `git fetch --no-tags <remote> refs/tags/<name>:refs/tags/<name>` | "Fetch Tag" for a tag only on the remote; never overwrites a differing local tag |
| List stashes | `git stash list --format=…` | |
| Stash from the toolbar | `git symbolic-ref -q --short HEAD`, `git log -1 --format=%s HEAD`, then `git stash push --include-untracked -m "WIP on <branch>: <subject>"` | Runs at once. `git stash list` before and after tells whether a stash was made, `git status --porcelain --untracked-files=all` records what it left |
| Stash with a message / only staged changes | `git stash push [--include-untracked] [-m <message>]`, `git stash push --staged -m <message>` | From the Stash button's menu |
| Undo the stash just made | `git stash list`, `git rev-parse --verify <stash>^1`, `git rev-parse --verify HEAD`, `git status --porcelain --untracked-files=all`, then `git stash pop --index stash@{0}` | Only while the stash is the newest, HEAD is where it was made and the working tree is as the stash left it |
| Stash local changes and retry a refused command | `git stash push --include-untracked -m "GitBonsai: before <command>"`, the command, `git stash pop --index <selector>` (retried as `git stash pop <selector>` on "Conflicts in index") | Offered when local changes stop a cherry-pick, revert, merge or rebase. A failure without an operation in progress pops at once, and if that pop fails the error names the stash; a stop on conflicts keeps the stash; a conflicting pop keeps it too |
| Apply / pop / drop | `git stash apply\|pop\|drop <selector>` | Drop asks first |
| Branch from a stash | `git stash branch <name> <selector>` | |

## Worktrees

| Operation | Git command | Notes |
|---|---|---|
| New worktree | `git worktree add [-b <branch> \| --detach] <path> <commit>` or `git worktree add <path> <branch>` | The Worktrees plus in the sidebar checks out a picked local branch that no worktree has with the second form, anything else with `-b` and the new branch's name |
| Remove | `git worktree remove [--force] <path>` | Asks first; can delete its branch too |
| Lock / unlock | `git worktree lock [--reason <text>] <path>` / `git worktree unlock <path>` | |
| Prune | `git worktree prune` | |

## Remotes

| Operation | Git command | Notes |
|---|---|---|
| List remotes | `git remote` | For the Tags list when it opens, and after every refresh while it is closed so that tag pills in the history offer push and remote delete per remote |
| Time of the last fetch | `git rev-parse --git-common-dir`, then the modification date of its `FETCH_HEAD` | Shown on the Fetch button; a repository never fetched has no date |
| Add a remote | `git check-ref-format refs/remotes/<name>/test` while typing the name, then `git remote add -- <name> <url>`; with "Fetch after adding" `git fetch --no-prune <name>` | From the sidebar's "Add Remote…". A remote without fetched branches still gets its sidebar header, from `git remote` |
| Edit a remote | `git remote rename -- <old> <new>` and/or `git remote set-url -- <name> <url>` | Only what changed; the URL is read with `git config -z --get-regexp ^remote\..*\.url$`. A rename moves its remote branches and the upstream of local branches |
| Remove a remote | `git remote remove -- <name>` | Asks first; its remote branches go, local branches that tracked it lose their upstream |
| Fetch all | `git fetch --all --prune` | Every fetch ends with the in-place refresh, so fetched commits enter the history. While a fetch, pull or push runs, its toolbar button offers Cancel, which terminates git and its helpers and refreshes |
| Automatic fetch | `git fetch --all --prune` | Visible tab only, on activation and periodically (`AutoFetchPolicy`), and never while a fetch, pull or push runs. Reads `git remote` and `git rev-parse --git-path` for an operation in progress first and skips without a remote or during a rebase, merge, cherry-pick or revert |
| Fetch one remote | `git fetch --prune\|--no-prune <remote>` | |
| Fetch tags | `git fetch --all --tags` | |
| Upstream and ahead/behind | `git config --get branch.<b>.remote`, `git config --get branch.<b>.merge`, `git rev-list --left-right --count refs/heads/<b>...<b>@{upstream}` | Counts next to Pull and Push |
| Default pull mode | `git config --type=bool-or-str --get pull.rebase`, `… --get pull.ff` | `pull.rebase` first, then `pull.ff`; without either fast-forward only |
| Pull, fast-forward only | `git pull --no-rebase --ff-only --autostash` | Every pull runs with `GIT_EDITOR=true` and carries local changes with `--autostash`. When applying them again conflicts, git exits 0 with "…resulted in conflicts", keeps the stash `autostash` and leaves the conflicts in the working tree; a toast with "Konflikte anzeigen" and the status line say so |
| Pull, merge | `git pull --no-rebase --ff --no-edit --autostash` | On failure `git rev-parse --verify --quiet MERGE_HEAD` tells a stopped merge; its conflicts are listed with `git diff --name-only -z --diff-filter=U` (index queue) |
| Pull, rebase | `git pull --rebase --autostash` | |
| Set upstream before a pull | `git branch --set-upstream-to=<remote>/<branch> <b>` | Then pulls with the default mode |
| Pull a branch from its context menu: where it is checked out | `git worktree list --porcelain`, `git rev-parse --path-format=absolute --show-toplevel --git-common-dir` | The checked-out branch takes the normal pull with the default mode |
| Pull a branch that is checked out nowhere | `git fetch --no-write-fetch-head <remote> refs/heads/<upstream>:refs/heads/<b>` | One command fetches and moves the ref; git refuses anything but a fast-forward (`[rejected] … (non-fast-forward)`) and also updates `<remote>/<upstream>`. Position before and after with `git rev-parse --verify refs/heads/<b>^{commit}`, commits taken with `git rev-list --count <old>..<new>` |
| Pull a branch checked out in another worktree | `git -C <worktree> pull --no-rebase --ff-only --autostash` | Through that worktree's own index queue, with `GIT_EDITOR=true`; a conflicting autostash is named in the toast and status line |
| Diverged branch: counts | `git rev-list --left-right --count refs/heads/<b>...<b>@{upstream}` | After the refused attempt, which already fetched. Behind 0 is reported as up to date |
| Diverged branch: reset to the upstream | `git rev-parse --verify <b>@{upstream}^{commit}`, `git update-ref -m "reset: moving to <b>@{upstream}" refs/heads/<b> <upstream sha> <old sha>` | Only for a branch checked out nowhere, chosen in the question about the diverged branch; Undo brings the local commits back. The old value guards against a branch that moved meanwhile |
| Push to the upstream | `git push <remote> refs/heads/<b>:refs/heads/<upstream branch>` | From the toolbar for the current branch; from a branch's context menu ("Push <branch>") for any local branch with an upstream |
| First push | `git push -u <remote> refs/heads/<b>:refs/heads/<name>` | Sets the upstream |
| Push after a non-fast-forward rejection | `git push --force-with-lease <remote> refs/heads/<b>:refs/heads/<upstream branch>` | Only after a confirmation; never `--force`. When the lease is stale, `git fetch --no-prune <remote>` follows, so the history shows the remote's new commits |
| Push tags | `git push <remote> --tags` | |
