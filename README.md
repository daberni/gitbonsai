# GitBonsai

A native macOS Git client that shapes your history the way a bonsai is shaped: prune, wire, graft. A graph-centric UX, built natively in AppKit on top of the plain `git` binary. A spike that moves the settings window to SwiftUI is under review; history, diff, sidebar and command bar stay AppKit.

![GitBonsai, light](docs/screenshots/main-window-light.png)
![GitBonsai, dark](docs/screenshots/main-window-dark.png)

See [docs/feature-overview.md](docs/feature-overview.md) for scope, [docs/architecture.md](docs/architecture.md) for the engine design, and [docs/screens.md](docs/screens.md) and [docs/flows.md](docs/flows.md) for the UI.

## Build and run

```bash
swift build
swift test
swift run GitBonsaiApp /path/to/repo
```

`scripts/make-synthetic-repo.sh bench/synthetic 100000` creates a 100k-commit repository with branches and merges for checks on a large history. `swift test --filter Performance` runs the performance budgets.

### App bundle

```bash
scripts/make-app-bundle.sh
open ".build/app/GitBonsai Dev.app"
```

The script builds the release binary and assembles `GitBonsai Dev.app` (bundle id `app.gitbonsai.dev`, its own defaults, macOS 26.0 or later) in `.build/app`, or in the directory given as its argument; `--release` builds `GitBonsai.app` with `app.gitbonsai` instead. Signing, notarization, packaging and the GitHub workflows are in [docs/release.md](docs/release.md). It compiles the app icon `docs/design/app-icon/AppIcon.icon` with `actool` into `Assets.car` (the layered icon macOS 26 renders in every appearance) and writes a classic `AppIcon.icns` with 16–512 pt at @1x and @2x for older surfaces, then signs the bundle (ad hoc unless `GITBONSAI_SIGN_IDENTITY` is set). It needs Xcode for `actool`.

### Screenshot harness

The app can render itself for checks without a human: `GITBONSAI_SCREENSHOT=/tmp/out.png swift run GitBonsaiApp /path/to/repo` writes the window to a PNG once loading has finished and quits.

Every switch gets its own line below, so parallel changes do not collide.

Run:

- Several paths open as tabs; without a path the app restores the tabs of the last session.
- `GITBONSAI_FOREGROUND=1` runs as a normal app with Dock icon and its window in front, for checks that need it; otherwise harness runs stay in the background and never take focus. Without a key window a real click on a control that refuses first mouse, such as a sheet's button, goes to the view under the point the way a key window would deliver it; a press into a table first makes the table first responder; the history table, like every list in the app, selects on the first click into a window that is not key; a sheet still open when the capture is taken is cancelled so the app can quit.
- Each harness run keeps its preferences and session in a defaults domain of its own inside a temporary run folder, removed when it quits (folders of crashed runs go at the next start); `GITBONSAI_DEFAULTS=<name>` shares the domain `app.gitbonsai.harness.<name>` between runs instead, for checks that read what an earlier run stored.
- Harness runs copy into and paste from a pasteboard of their own, never the user's clipboard.
- git in a harness run reads a global configuration of the run's own (`HOME` and `XDG_CONFIG_HOME` point into the run folder): author "GitBonsai Harness", no commit or tag signing, none of the user's aliases, hooks or tools. Set what a check needs in the fixture repository's own config.
- The capture waits until every scheduled harness step has run and the detail panel's file list has loaded; steps print in order before it. `GITBONSAI_CAPTURE_DELAY=<seconds>` waits that much longer, and `GITBONSAI_TIMEOUT=<seconds>` (default 120) captures anyway when steps are still pending then.

Sheets, questions and menus (shared by every area below):

- `GITBONSAI_FORM=key=value;…` fills the form sheet an action opens (keys `name`, `branch`, `path`, `message`, `remote`, `upstream`, `reason`, `checked=0|1`, depending on the sheet) and submits it; `GITBONSAI_FORM_CANCEL=1` cancels it instead.
- `GITBONSAI_CONFIRM=1` confirms a question, `GITBONSAI_CHOICE=<button title prefix>` picks one of several ways forward; without them the harness cancels. `GITBONSAI_SAVE_PATH=<file>` answers a save panel.
- `GITBONSAI_SHEET_SHOT=<png>` renders the sheet or question as filled, `GITBONSAI_MENU_SHOT=<png>` renders a menu the harness opened.

Window and tabs:

- `GITBONSAI_LANGUAGE=en|de` runs in that language for this launch only, without storing it.
- `GITBONSAI_APPEARANCE=light|dark` forces the appearance, `GITBONSAI_SELECT_ROW=n` selects a history row first.
- `GITBONSAI_NEW_TAB=1` shows the empty tab with the recently used repositories, `GITBONSAI_CLICK_TAB=n` switches tabs with a real click first.
- `GITBONSAI_REPOSITORY_FOLDERS=<folder>:<folder>` stores the repository folders in the run's defaults (empty for none); the empty tab is captured once their first scan finished, and each scan prints its duration and counts.
- `GITBONSAI_CLONE=1` opens the clone sheet, or `GITBONSAI_CLONE_CLICK=1` with a real click on the empty tab's "Clone…"; `GITBONSAI_CLONE_PASTE=<text>` fills the harness's own pasteboard first. `GITBONSAI_CLONE_FORM=url=…;path=…;branch=…;submodules=1;shallow=1` fills the sheet, `GITBONSAI_CLONE_SHOT=<png>` renders it (after a failure with the details open), `GITBONSAI_CLONE_RUN=1` clicks "Clone", `GITBONSAI_CLONE_SHOT_DURING=<png>` renders it once receiving passes a third and `GITBONSAI_CLONE_CANCEL_AT=<fraction>` clicks "Cancel" past that fraction. A slow clone comes from `GIT_BONSAI_GIT=<script>` that runs `git -c remote.origin.uploadpack=<throttling upload-pack> "$@"`.
- `GITBONSAI_WELCOME_SEARCH=<text>` types into the empty tab's search and `GITBONSAI_WELCOME_KEYS=down,up,return,cmd-return` presses those keys there with real key events; the list is printed after each, and `GITBONSAI_PRINT_WELCOME=1` prints it alone.
- `GITBONSAI_DRAG_TAB=from:to` drags a tab onto another tab's place with real mouse events and prints the resulting order.
- Every harness run prints what each tab's file watcher watches, each burst it reports and when it stops (`watcher`), and each reconciliation of a tab (`return refresh`): the triggers it gathered, its outcome and its duration. `GITBONSAI_RETURN_STEPS=print,outside,tab,activate,…` runs one step every two seconds: `print` prints every tab's history head, selection, branches, remote branches with their row, tags and counts, `outside` runs the script `GITBONSAI_OUTSIDE_SCRIPT=<file>` with `sh` in the first hidden tab's worktree and prints when it ended, `tab` selects the next tab and `activate` posts the app's activation and `fetch` runs the toolbar's Fetch in the visible tab; `activate+tab` runs both in one step, to show that they reconcile once.
- Harness runs start with the default window frame and panel widths; `GITBONSAI_KEEP_LAYOUT=1` with `GITBONSAI_DEFAULTS` restores what the previous harness run saved, and `GITBONSAI_WINDOW_FRAME=x,y,w,h[,zoomed][,fullscreen][,screen=<id>]` stores a placement as if an earlier launch had left it. A background run reports zoom and full screen instead of applying them, so it never shows its window.
- `GITBONSAI_PRINT_LAYOUT=1` prints the window's frame, screen, zoom and full screen and the panel widths; `GITBONSAI_RESIZE_WINDOW=<width>` resizes the window, `GITBONSAI_DRAG_DIVIDERS=<sidebar>,<detail>` drags the sidebar's and the detail panel's dividers that many points with real mouse events, and `GITBONSAI_DOUBLE_CLICK_DIVIDER=0|1` double-clicks one; the layout is printed after each.

History:

- `GITBONSAI_CHECKOUT=<branch>` checks a local branch out before the capture and `GITBONSAI_SWITCH_WORKTREE=<folder name>` moves the tab to another worktree.
- `GITBONSAI_RESET_ANSWER=reset|checkout|cancel` answers the question when checking out a branch that diverged from its remote branch.
- `GITBONSAI_GRAPH_WIDTH=<points>` sets the width of the graph column and `GITBONSAI_GRAPH_SCROLL=<points>` scrolls the graph sideways.
- `GITBONSAI_DRAG_GRAPH_TO=<points>` drags the boundary between graph and commit over the rows with real mouse events and prints the resulting width.
- `GITBONSAI_PRINT_HISTORY=<seconds>,…` prints the commit count, HEAD, the selected row with its scroll position, the status line and the first rows after loading and after each delay, and every full reload; `GITBONSAI_RUN_GIT=<argument>;…` runs that git command first and refreshes the history in place the way write actions do.
- `GITBONSAI_STATUS_STEPS=fetch,stage:<path>,outside:<shell command>,…` runs one step every two seconds in the tab (fetch all remotes, stage a path, run a command with `sh` in the worktree as a terminal would) and prints every change of the status line and the line before the next step.
- `GITBONSAI_HIDDEN_COLUMNS=label,sha` hides columns (label, graph, author, sha, date).
- `GITBONSAI_HISTORY_ORDER=date|authorDate|branchesTogether` reads the history in that order.
- `GITBONSAI_SEARCH=<text>` types into the commit search one character at a time with real key events and `GITBONSAI_SEARCH_KEYS=return,shift-return,escape,backspace,+<text>` then presses those keys in the field; the counter, the selected row and commit, the first responder and the dimmed visible rows are printed after each key.
- `GITBONSAI_REF_PILLS=<step>,…` drives the expansion of a row's cut-off ref pills with real mouse events, one step a second: `hover:<row>` rests on the row's labels, `brush:<row>` passes over them quicker than the hover delay, `counter:<row>` clicks its "+n", `away` moves onto the last row's commit text, `menu` prints the menu of the expanded labels, `click` and `double` click them, `pill=<n>` double-clicks the n-th pill in them; the expanded row, its card and pills are printed after each step.
- `GITBONSAI_COVERED_HOVER=1` moves onto the graph boundary of the first row the way tracking areas deliver it, uncovered, under the open command bar and after closing it, and prints whether the guide line shows, the cursor and the ref pills.
- `GITBONSAI_PILL_MENU=<step>,…` right-clicks with real events and prints the menu the view under the pointer gives, without opening it: `pill:<row>:<n>` the n-th ref pill of a row (0 is the rightmost), `corner:<row>:<n>` its frame corner just outside the capsule, `counter:<row>` the "+n" counter (expands instead), `row:<row>` the commit text, `overlay:<n>` a pill of the expanded labels; `GITBONSAI_PILL_MENU_PICK=<title>` or `<title>/<title>` then chooses an entry of the last menu printed, and `GITBONSAI_MENU_SHOT=<png>` opens the last step's menu on screen for a moment and renders it.
- `GITBONSAI_COMMIT_MENU=<row>` right-clicks a history row with a real event and prints the menu (AppKit shows it on screen above other apps for a moment), and `GITBONSAI_MENU_PICK=<title>` or `<title>/<title>` chooses an entry; `GITBONSAI_MENU_LIST=<row>` only prints the visible entries without opening the menu, right before the capture; entries that search the repository, such as the detected rebase base, hold the capture until they have their final titles.

Remotes and rebase:

- `GITBONSAI_TOOLBAR_LAYOUT=1` prints the Pull and Push badges (`↓n ↑n`, `-` hidden, `!` no upstream), the frame of every toolbar action button (`▾` for those with a menu) and the Pull and Push tooltips, to check that badges never move a button.
- `GITBONSAI_PRINT_FETCH_STATE=<seconds>,…` prints the toolbar's fetch state after each delay, with `[spinner]` while a fetch runs and its tooltip.
- `GITBONSAI_FETCH_MENU=1` prints the Fetch button's menu with each entry's git command without opening it, and `GITBONSAI_FETCH_PICK=<title>` runs an entry and prints the status line afterwards.
- `GITBONSAI_MENU_RUN=<row>:<title>` runs an entry of a history row's menu without opening the menu; `GITBONSAI_ONTO=<base>` chooses the old base of the interactive rebase sheet by name or revision when it opens, as picking it in the ref picker would.
- `GITBONSAI_BANNER_CLICK=continue|skip|abort` clicks a button of the rebase, cherry-pick, revert or merge banner with a real click and prints the banner before and after.
- `GITBONSAI_REBASE_SCRIPT=<step>;…` drives the interactive rebase sheet with real clicks, drags and keys once "Rebase <branch> interactively onto this Commit…" opened it: `drag:<row>><gap>`, `click:<row>`, `key:<key>` (letter, `opt-up`, `opt-down`), `popup:<row>=<action>`, `subject:<row>=<text>`, `message:<text>` (`\n` for a new line), `base:<revision>` (the old base), `resize:<column>><points>` (drags a column edge over the rows), `toggle:update-refs|autostash`, `size:<width>x<height>`, `print`, `shot:<png>`, `start`, `cancel`. `GITBONSAI_REBASE_MENU=<row>,…` prints a row's interactive rebase entries with the reason a disabled one gives.
- `GITBONSAI_PRINT_SELECTION=<seconds>,…` prints whether the toast shows, the selected history row, whether it is HEAD and whether a diff covers the history after each delay; every toast is printed when it appears with its action in brackets.
- `GITBONSAI_REWORD_SCRIPT=<step>;…` edits a commit message in place in the detail panel with real clicks and keys: `select:<row>` (selects the row without a click), `menu` (the commit menu's "Edit Commit Message"), `dblclick` (on the subject), `pencil`, `cmd-e` (the main menu entry's validation and action), `subject:<text>`, `body:<text>`, `key:<key>` (`escape`, `cmd-return`), `save`, `cancel`, `print` (log, selection, editor, status line), `shot:<png>`, `wait:<seconds>`.
- `GITBONSAI_EDIT_AMEND=<subject>` at an edit stop clicks "Amend Commit…" in the banner, types the subject into the commit form, clicks Amend and then Continue; `GITBONSAI_REBASE_UNDO=1` clicks "Undo" in the status line.
- `GITBONSAI_FETCH=<title>`, `GITBONSAI_PULL=<title>`, `GITBONSAI_PUSH=<title>` or `GITBONSAI_STASH=<title>` clicks the chevron of that toolbar split button with a real click, prints its menu (an empty title stops there), chooses the entry and prints the status line, the banner, the ahead/behind counts and the button frames afterwards; the first-push and upstream sheets take `GITBONSAI_FORM`.
- `GITBONSAI_TOOLBAR_DEFAULT=Fetch|Pull|Push|Stash` clicks the main part of that split button with a real click, which runs the first enabled entry of its menu, and prints the status line, the banner and the ahead/behind counts afterwards.
- `GITBONSAI_REMOTE_STEPS=<step>;…` drives the toolbar while a fetch, pull or push runs, one step every half second: `click:Fetch|Pull|Push` clicks the main part with a real click and prints the menu it opens, `cancel:<button>` opens the running button's menu and chooses Cancel, `print` prints the remote buttons (enabled, `[running]`, tooltip), the fetch state and the status line, `shot:<png>` renders the window, `wait:<seconds>`. A slow remote comes from `remote.origin.uploadpack` or `remote.origin.receivepack` set to a script that sleeps and then runs `git-upload-pack` or `git-receive-pack`.

Sidebar:

- `GITBONSAI_OPEN_PANEL=tags|stashes` opens that popover with a real press on its sidebar row and prints its entries; then `GITBONSAI_PANEL_FILTER=<text>` filters, `GITBONSAI_PANEL_SELECT=<n>` presses entry n and prints where the history went, `GITBONSAI_PANEL_SHOT=<png>` renders the list, and `GITBONSAI_PANEL_BUTTON=<title>` presses a button below it or `GITBONSAI_PANEL_MENU=<title>` runs an entry of the selected row's menu without opening it. With `GITBONSAI_PRINT_HISTORY` the history is also printed right before the button or menu action.
- For the Tags list the harness waits until every remote answered `ls-remote` and prints each tag's marks and tooltip; `GITBONSAI_PANEL_SCOPE=<title>` picks a filter scope such as "Local only" first and `GITBONSAI_PANEL_SCROLL=<lines>` scrolls the list with a wheel event. After a button or menu action the harness samples the marks until the remotes answered anew, prints the fewest marked rows, the list and whether the popover is still open; `GITBONSAI_PANEL_SHOT_DURING=<png>` and `GITBONSAI_PANEL_SHOT_AFTER=<png>` render the list while the refresh runs and after it. A slow remote is simulated with `git config remote.origin.uploadpack <script that sleeps, then runs git-upload-pack>`.
- `GITBONSAI_SHEET_CLICK=confirm|cancel` shows confirmations as real sheets on the window instead of answering them and clicks that button with real events; it prints whether a popover is still open behind the sheet.
- `GITBONSAI_SHEET_KEY=escape|return` with `GITBONSAI_FOREGROUND=1` shows forms and confirmations as real sheets and posts that key to the event queue once the sheet is up; it prints the focus, the buttons' keys, the button that ended the sheet and the field contents. `GITBONSAI_FORM` fills a form first, and `GITBONSAI_SHEET_FOCUS=message` focuses its multi-line message. The discard confirmation takes the key too. Without `GITBONSAI_FOREGROUND=1` the switch is ignored, because pressing the key activates the app.
- `GITBONSAI_TOOLBAR=Stash|Pop` presses that toolbar button and prints whether it was enabled; the "Stash with Message…" sheet takes `GITBONSAI_FORM`.
- `GITBONSAI_TOAST_SHOT=<png>` renders the window once the first toast with an action shows; `GITBONSAI_TOAST_CLICK=<action>` then clicks that action ("Undo", "Details", "Show conflicts") with a real click and prints the status line and the working tree.
- Failure sheets are printed with their actions in braces and not shown; `GITBONSAI_REPORT_SHOT=<png>` renders one with "Git Output" open. `GITBONSAI_REPORT_CLICK=<button>` shows them as real sheets and clicks that button, `GITBONSAI_REPORT_DETAILS=1` first opens "Git Output" with a click; the sheet's buttons and the output box's frame are printed.
- `GITBONSAI_SIDEBAR_SCROLL=<points>` scrolls the sidebar down and prints the left edge of its scroller next to the right edge of the status slot column; the capture does not draw scrollers, so these numbers show whether one covers the slot.
- `GITBONSAI_SIDEBAR_MENU_LIST=<subject>` prints a sidebar row's context menu without opening it (`branch:<name>`, `branch:origin/<name>`, `worktree:<folder>`), and `GITBONSAI_SIDEBAR_MENU_PICK=<title prefix>` runs one of its entries; `GITBONSAI_SIDEBAR_MENU=<subject>` right-clicks the row with a real event instead (the menu shows on screen for a moment); `GITBONSAI_NEW_BRANCH=plus|toolbar|worktree` opens the new-branch sheet with a real click on the Local plus or the toolbar's Branch button, or the new-worktree sheet with a click on the Worktrees plus.
- `GITBONSAI_SIDEBAR_MENU_PICK` together with `GITBONSAI_SIDEBAR_MENU` runs the entry after the real right-click, from the menu that row builds. A diverged branch after "Pull <branch>" asks a question that `GITBONSAI_CHOICE` answers. `GITBONSAI_PRINT_STATUS=<seconds>,…` prints the status line, the toolbar counts and the selected row after each delay.
- `GITBONSAI_NEW_BRANCH_SCRIPT=<step>;…` drives the open new-branch sheet with real clicks and keys: `click:name|picker|worktree|checkout|path|create|cancel`, `click:row:<n>` (entry n of the open ref picker), `type:<text>`, `key:return|escape|up|down|delete|space|tab|backtab` (Tab and ⇧Tab print the focus they lead to), `focus` (the focused control and whether it shows its focus), `print` (the form's state and the picker's entries) and `shot:<png>` (the sheet with the open picker). `GITBONSAI_FULL_KEYBOARD_ACCESS=1` makes the app's own controls behave as with full keyboard access on (System Settings → Keyboard → Keyboard navigation), which AppKit reads only from the system setting.
- `GITBONSAI_ADD_REMOTE=1` opens the add-remote sheet with a real click on the sidebar's "Add Remote…"; `GITBONSAI_SIDEBAR_MENU_LIST=remote:<name>` lists a remote header's menu and `GITBONSAI_SIDEBAR_MENU_PICK=Edit` opens its edit sheet. `GITBONSAI_REMOTE_SCRIPT=<step>;…` drives the open sheet: `click:name|url|fetch|confirm|cancel`, `type:<text>`, `clear:name|url`, `key:return|escape`, `print` and `shot:<png>`. `GITBONSAI_PRINT_REMOTES=1` prints the sidebar's remotes and whether each has its header.

Settings:

- `GITBONSAI_SETTINGS=general|apps|git|avatars` opens the settings window on that section and captures it instead of the main window; a run opens it there without changing the section it reopens on.
- `GITBONSAI_SETTINGS_SCRIPT=<step>;…` drives the open settings section, half a second per step, before the capture. The sections are SwiftUI, so controls are found in the accessibility tree SwiftUI publishes once the harness sets `AXEnhancedUserInterface` on itself: `click:<identifier or label>` (a real click at the element's frame, on the box for checkboxes and radio buttons, then printing how long the control took to show its new state and the window to reach its final height; toolbar tabs too), `action:<element>=<name>` (a named accessibility action, such as an app row's "Make default"), `scroll:<points>` (a real scroll-wheel event, positive scrolls down), `type:<text>`, `key:return|tab|escape`, `print` (section, window size and every element with role, label, value, identifier and enabled state), `shot:<png>`, `wait:<seconds>`. Pop-up menus and open panels are not driven.
- `GITBONSAI_AUTO_FETCH=<seconds>` turns automatic fetching on for the run: on activation and when a tab becomes visible, and periodically at that interval unless it is 0. Each decision is printed; harness runs otherwise never fetch automatically.
- `GITBONSAI_AUTO_FETCH_STEPS=activate,tab,…` posts the app's activation or selects the next tab, one step every two seconds, and prints every tab's toolbar counts after each step.

Avatars (harness runs load none unless asked):

- `GITBONSAI_AVATARS=off|remote|gravatar` sets "Avatars" (Initials only, From the remote host, Remote host and Gravatar) for the run; `GITBONSAI_AVATAR_CACHE=<folder>` keeps the disk cache there, an empty folder for a cold load; without it harness runs use a temporary folder.
- `GITBONSAI_AVATAR_FALLBACK=initials|tintedInitials|pattern` draws authors without avatar in that style.
- `GITBONSAI_AVATAR_LOG=1` prints every avatar request with status, host and path and a running number; `GITBONSAI_AVATAR_SWEEP=<rows>` pages the history down to that row, half a second per screen.

Command bar:

- `GITBONSAI_COMMAND_BAR=<step>;…` drives the command bar once the tab has loaded, half a second per step, then captures the window: `open` (⌘⇧P through the main menu), `type:<text>` and `key:down|up|return|opt-return|escape|backspace` as real key events, `click:<row>`, `print` (step, field, every row with selection, context, reason and shortcut), `status` (branch, HEAD, upstream counts and status line), `wait:<seconds>`, `shot:<png>`. Each run starts without recently used commands. Editors, terminals, the Finder, default apps and the diff tool are never launched under the harness; the action prints the app and what it would open.
- `GITBONSAI_PRINT_MENU=1` prints the generated menu bar a second after loading, each item with shortcut and enabled state (with `GITBONSAI_NEW_TAB=1` for the empty tab); in a `GITBONSAI_COMMAND_BAR` script `menu` prints it, `shortcut:ctrl-cmd-s` presses a key equivalent through the main menu and `pick:Branch/Checkout Branch…` chooses an item; `settings` opens the settings window and makes it key and `windows` prints the visible windows, the key window and the tabs (a key window needs `GITBONSAI_FOREGROUND=1`).
- `GITBONSAI_PRINT_OPENERS=1` prints for every known terminal and editor whether it is installed and how it would open the tab's folder (document, URL scheme or its binary), then the editors and terminals the settings list and the default of each.
- Rendered captures cannot draw Liquid Glass, so the harness renders the window without its glass views and composites each one over it: the backdrop blurred and saturated, the tint, the content and a hairline rim. Refraction and highlights only show with `GITBONSAI_FOREGROUND=1`, where `shot:` asks `screencapture` for the real window, which needs Screen Recording for the app.

Files, diffs and commits:

- `GITBONSAI_OPEN_FILE=<path>` with `GITBONSAI_OPEN_SOURCE=unstaged|staged|untracked` opens a file's diff (without a source: the file in the selected commit), and `GITBONSAI_HUNK_ACTION=<n>` stages or unstages hunk n; `GITBONSAI_WINDOW_WIDTH=<points>` resizes the window before the diff opens.
- `GITBONSAI_OPEN_ORIGINAL=<path>` passes the path before a rename or copy with `GITBONSAI_OPEN_FILE`, as the file lists do; `GITBONSAI_PRINT_DIFF_HEADER=1` prints the header's change letter, path and tooltip.
- `GITBONSAI_CLICK_DIFF_MODE=diff|file` clicks that half of the "Diff | File" toggle in the open diff with a real click and prints the numbers of the top and bottom line.
- `GITBONSAI_DIFF_NEXT=<n>` clicks the ↓ of the hunk navigation n times and prints the top line after each jump.
- `GITBONSAI_DIFF_SCROLL_THEN_FILE=<x>,<y>,<n>` scrolls the open diff to that offset, clicks the n-th file of the detail panel with a real click and prints the offset and top line before and after.
- `GITBONSAI_CLICK_DIFF_CLOSE=1` clicks the close button of the open diff with a real click and prints whether the diff is still shown.
- `GITBONSAI_DIFF_MODE=diff|file|remembered` starts the diff in that mode; harness runs otherwise start in "Diff", and `remembered` reads the choice an earlier harness run with the same `GITBONSAI_DEFAULTS` stored.
- `GITBONSAI_DIFF_INVISIBLES=1|0|remembered` starts the diff with or without invisible characters; harness runs otherwise start without them.
- `GITBONSAI_DIFF_WORDS=1`, `GITBONSAI_DIFF_WHITESPACE=all|changes` and `GITBONSAI_DIFF_BLANK_LINES=1` start the diff with Word Diff, Ignore Whitespace (or its amount) and Ignore blank Lines; `GITBONSAI_DIFF_INVISIBLES=remembered` reads all options an earlier run stored.
- `GITBONSAI_DIFF_OPTION=<title>` prints the diff options menu with each entry's state, chooses that entry without opening the menu and prints it again.
- `GITBONSAI_IMAGE_MODE=sideBySide|swipe|onionSkin|text` starts an image diff in that mode (harness default: side by side); `GITBONSAI_CLICK_IMAGE_MODE=<mode>` clicks that segment of the image toggle, `GITBONSAI_IMAGE_SWIPE=<0…1>` drags the swipe line and `GITBONSAI_IMAGE_OPACITY=<0…1>` the onion skin slider, all with real mouse events, printing the state after each step.
- File rows are counted from 0 in every switch that takes `<n>` for a file. `GITBONSAI_CLICK_FILE=<n>` clicks file n in the detail panel with real mouse events and prints which diff opened.
- `GITBONSAI_FILE_KEYS=down,down,up` then presses arrow keys through the window and prints the first responder, the history row and the opened diff after each.
- `GITBONSAI_SELECT_SUBJECT=1` drags across the commit subject in the detail panel with real mouse events and prints the selection.
- `GITBONSAI_COMMIT_SUBJECT`, `GITBONSAI_COMMIT_BODY` (with `\n`), `GITBONSAI_AMEND=1` and `GITBONSAI_COMMIT_RUN=1` fill the commit form, tick amend and click the commit button; `GITBONSAI_COMMIT_RUN=amend-key` presses ⌥⌘⏎ and `all-key` ⇧⌘⏎ instead, `GITBONSAI_COMMIT_SHIFT=1` holds ⇧ so the button shows "Commit All", `GITBONSAI_COMMIT_COAUTHOR=Name <email>` adds a co-author and `GITBONSAI_COMMIT_SIGNOFF=1` ticks sign-off.
- `GITBONSAI_CLICK_HUNK_DISCARD=<n>` clicks "Discard Hunk" of hunk n in the open diff, `GITBONSAI_HOVER_FILE=<n>` moves the mouse onto the n-th file row and `GITBONSAI_CLICK_FILE_DISCARD=<n>` clicks its discard button; the confirmation sheet is answered with `GITBONSAI_DISCARD_ANSWER=confirm|cancel` by a real click, or, without an answer, written to `GITBONSAI_SHEET_SCREENSHOT=<path>`.
- `GITBONSAI_FILE_SELECT=<step>;…` selects files with real clicks, one step every 0.8 seconds, and prints the selected files, the history pane (graph, diff or stacked diffs) and the status after each: `<n>`, `cmd:<n>`, `shift:<n>`, `menu:<n>` (entries with enabled state and reason), `pick:<title>`, `bar:<title>` (a button above stacked diffs), `close`, `shot:<png>`.
- `GITBONSAI_FILE_MENU=<n>` prints the context menu of the n-th file row (⌥ alternates marked) without opening it on screen, and `GITBONSAI_FILE_MENU_PICK=<title>` chooses an entry.
- `GITBONSAI_OPEN_CONFLICT=<path>` opens the conflict view of an unmerged file, and `GITBONSAI_CONFLICT_SCRIPT=<step>;…` drives it with real clicks and key equivalents, half a second per step. In the history pane: `link:<change>:ours|theirs|both|merge|undo` (action rows), `next`, `previous`, `key:next|previous|escape` (⌥⌘↓/⌥⌘↑/Esc), `resolve` (Mark resolved), `action:<n>` (button n of a whole-file choice), `continue` (the banner's Continue), `window` (Resolve…); in the merge window: `take:<change>:ours|theirs`, `ignore:<change>:ours|theirs` (gutter buttons), `wand`, `base`, `wresolve`, `wshot:<png>`, `wclose`; always `print` (pane, header, change states, merge window, unmerged paths, banner and its Continue), `shot:<png>`, `wait:<seconds>`.
- `GITBONSAI_CLICK_COMMIT_COPY=full|short` clicks the copy icon next to the commit SHA with a real click (⌥ held for `short`) and prints what landed on the harness's own pasteboard and the icon's state, and the frames of the button, its image, its line and the panel's content before the click, with the checkmark and after it; the capture shows the checkmark.
- `GITBONSAI_CLICK_PARENT=<n>` clicks the n-th parent link in the commit header with a real click and prints the selected commit before and after.
- `GITBONSAI_NAVIGATE=<step>;…` drives navigation and comparisons with real clicks and keys, one step every `GITBONSAI_NAVIGATE_INTERVAL` seconds (default 1.5), and prints after each whether a diff is open, the selected commits, the comparison panel and the focus: `file:<n>`, `row:<n>`, `cmd:<n>`, `shift:<n>`, `key:up|down|cmd-up|cmd-down|return|escape` (⌘↓ and ⌘↑ go to the parent and child), `parent:<n>`, `sidebar:<subject>`, `sidebar2:<subject>` (double click), `tags:<n>`, `search:<text>`, `git:<argument>,…` (runs git and refreshes like a write action), `stage:<path>`, `base` (the "since common base" switch), `close`, `focus:history`, `tooltips:<row>` (the tooltip the row registers over labels, subject, author and date), `width:<points>`, `shot:<png>`.

