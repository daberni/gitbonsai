# GitBonsai

A native macOS Git client that shapes your history the way a bonsai is shaped: prune, wire, graft. A graph-centric UX, built in SwiftUI and AppKit on top of the plain `git` binary.

Status: spike. See [docs/feature-overview.md](docs/feature-overview.md) for scope and estimates, [docs/architecture.md](docs/architecture.md) for the engine design, and [docs/screens.md](docs/screens.md) and [docs/flows.md](docs/flows.md) for the UI.

## Run the spike

```bash
swift build
swift test
swift run GitBonsaiApp /path/to/repo
```

`scripts/make-synthetic-repo.sh bench/synthetic 100000` creates a 100k-commit repository with branches and merges for benchmarks.

### App bundle

```bash
scripts/make-app-bundle.sh
open .build/app/GitBonsai.app
```

The script builds the release binary and assembles `GitBonsai.app` (bundle id `app.gitbonsai`, macOS 26.0 or later) in `.build/app`, or in the directory given as its argument. It compiles the app icon `docs/design/app-icon/AppIcon.icon` with `actool` into `Assets.car` (the layered icon macOS 26 renders in every appearance) and writes a classic `AppIcon.icns` with 16–512 pt at @1x and @2x for older surfaces, then signs the bundle ad hoc. It needs Xcode for `actool`.

### Screenshot harness

The app can render itself for checks without a human: `GITBONSAI_SCREENSHOT=/tmp/out.png swift run GitBonsaiApp /path/to/repo` writes the window to a PNG once loading has finished and quits.

Every switch gets its own line below, so parallel changes do not collide.

Run:

- Several paths open as tabs; without a path the app restores the tabs of the last session.
- `GITBONSAI_FOREGROUND=1` runs as a normal app with Dock icon and its window in front, for checks that need it; otherwise harness runs stay in the background and never take focus. Without a key window a real click on a control that refuses first mouse, such as a sheet's button, goes to the view under the point the way a key window would deliver it; a press into a table first makes the table first responder; the history table, like every list in the app, selects on the first click into a window that is not key; a sheet still open when the capture is taken is cancelled so the app can quit.
- Harness runs keep their session in their own defaults domain (`app.gitbonsai.harness`).
- `GITBONSAI_CAPTURE_DELAY=<seconds>` waits longer before the capture.
- `GITBONSAI_TRACE_STARTUP=1` prints each state of the tab row (with whether the window is visible) and each sidebar rebuild with the time since launch, to count redraws while the app opens.

Window and tabs:

- `GITBONSAI_LANGUAGE=en|de` runs in that language for this launch only, without storing it.
- `GITBONSAI_APPEARANCE=light|dark` forces the appearance, `GITBONSAI_SELECT_ROW=n` selects a history row first.
- `GITBONSAI_NEW_TAB=1` shows the empty tab with the recently used repositories, `GITBONSAI_CLICK_TAB=n` switches tabs with a real click first.
- `GITBONSAI_REPOSITORY_FOLDERS=<folder>:<folder>` stores the repository folders in the harness defaults (empty for none); the empty tab is captured once their first scan finished, and each scan prints its duration and counts.
- `GITBONSAI_CLONE=1` opens the clone sheet, or `GITBONSAI_CLONE_CLICK=1` with a real click on the empty tab's "Klonen …"; `GITBONSAI_CLONE_PASTE=<text>` fills the harness's own pasteboard first. `GITBONSAI_CLONE_FORM=url=…;path=…;branch=…;submodules=1;shallow=1` fills the sheet, `GITBONSAI_CLONE_SHOT=<png>` renders it (after a failure with the details open), `GITBONSAI_CLONE_RUN=1` clicks "Klonen", `GITBONSAI_CLONE_SHOT_DURING=<png>` renders it once receiving passes a third and `GITBONSAI_CLONE_CANCEL_AT=<fraction>` clicks "Abbrechen" past that fraction. A slow clone comes from `GIT_BONSAI_GIT=<script>` that runs `git -c remote.origin.uploadpack=<throttling upload-pack> "$@"`.
- `GITBONSAI_WELCOME_SEARCH=<text>` types into the empty tab's search and `GITBONSAI_WELCOME_KEYS=down,up,return,cmd-return` presses those keys there with real key events; the list is printed after each, and `GITBONSAI_PRINT_WELCOME=1` prints it alone.
- `GITBONSAI_DRAG_TAB=from:to` drags a tab onto another tab's place with real mouse events and prints the resulting order.
- Every harness run prints what each tab's file watcher watches, each burst it reports and when it stops (`watcher`), and each reconciliation of a tab (`return refresh`): the triggers it gathered, its outcome and its duration. `GITBONSAI_RETURN_STEPS=print,outside,tab,activate,…` runs one step every two seconds: `print` prints every tab's history head, selection, branches, remote branches with their row, tags and counts, `outside` runs the script `GITBONSAI_OUTSIDE_SCRIPT=<file>` with `sh` in the first hidden tab's worktree and prints when it ended, `tab` selects the next tab and `activate` posts the app's activation and `fetch` runs the toolbar's Fetch in the visible tab; `activate+tab` runs both in one step, to show that they reconcile once.
- Harness runs start with the default window frame and panel widths; `GITBONSAI_KEEP_LAYOUT=1` restores what the previous harness run saved, and `GITBONSAI_WINDOW_FRAME=x,y,w,h[,zoomed][,fullscreen][,screen=<id>]` stores a placement as if an earlier launch had left it. A background run reports zoom and full screen instead of applying them, so it never shows its window.
- `GITBONSAI_PRINT_LAYOUT=1` prints the window's frame, screen, zoom and full screen and the panel widths; `GITBONSAI_RESIZE_WINDOW=<width>` resizes the window, `GITBONSAI_DRAG_DIVIDERS=<sidebar>,<detail>` drags the sidebar's and the detail panel's dividers that many points with real mouse events, `GITBONSAI_DIVIDER_SWEEP=<sidebar>,<detail>` moves them in 60 drawn steps and prints the time a step takes, and `GITBONSAI_DOUBLE_CLICK_DIVIDER=0|1` double-clicks one; the layout is printed after each.

History:

- `GITBONSAI_CHECKOUT=<branch>` checks a local branch out before the capture and `GITBONSAI_SWITCH_WORKTREE=<folder name>` moves the tab to another worktree.
- `GITBONSAI_RESET_ANSWER=reset|checkout|cancel` answers the question when checking out a branch that diverged from its remote branch.
- `GITBONSAI_GRAPH_WIDTH=<points>` sets the width of the graph column and `GITBONSAI_GRAPH_SCROLL=<points>` scrolls the graph sideways.
- `GITBONSAI_DRAG_GRAPH_TO=<points>` drags the boundary between graph and commit over the rows with real mouse events and prints the resulting width.
- `GITBONSAI_PRINT_HISTORY=<seconds>,…` prints the commit count, HEAD, the selected row with its scroll position, the status line and the first rows after loading and after each delay, and every full reload; `GITBONSAI_RUN_GIT=<argument>;…` runs that git command first and refreshes the history in place the way write actions do.
- `GITBONSAI_FRAME_TRACE=1` (with `GITBONSAI_PRINT_HISTORY`) prints the history table on every run loop turn in which it changed: row count, visible rows, scroll position, selection, and the visible rows that show another commit or draw another graph row than the last time that commit was on screen; whole-table reloads, applied row diffs and row insertions are printed as they happen.
- `GITBONSAI_STATUS_STEPS=fetch,stage:<path>,outside:<shell command>,…` runs one step every two seconds in the tab (fetch all remotes, stage a path, run a command with `sh` in the worktree as a terminal would) and prints every change of the status line and the line before the next step.
- `GITBONSAI_HIDDEN_COLUMNS=label,sha` hides columns (label, graph, author, sha, date).
- `GITBONSAI_SEARCH=<text>` types into the commit search one character at a time with real key events and `GITBONSAI_SEARCH_KEYS=return,shift-return,escape,backspace,+<text>` then presses those keys in the field; the counter, the selected row and commit, the first responder and the dimmed visible rows are printed after each key.
- `GITBONSAI_REF_PILLS=<step>,…` drives the expansion of a row's cut-off ref pills with real mouse events, one step a second: `hover:<row>` rests on the row's labels, `brush:<row>` passes over them quicker than the hover delay, `counter:<row>` clicks its "+n", `away` moves onto the last row's commit text, `menu` prints the menu of the expanded labels, `click` and `double` click them; the expanded row, its card and pills are printed after each step.
- `GITBONSAI_PILL_MENU=<step>,…` right-clicks with real events and prints the menu the view under the pointer gives, without opening it: `pill:<row>:<n>` the n-th ref pill of a row (0 is the rightmost), `corner:<row>:<n>` its frame corner just outside the capsule, `counter:<row>` the "+n" counter (expands instead), `row:<row>` the commit text, `overlay:<n>` a pill of the expanded labels; `GITBONSAI_PILL_MENU_PICK=<title>` or `<title>/<title>` then chooses an entry of the last menu printed.
- `GITBONSAI_COMMIT_MENU=<row>` right-clicks a history row with a real event and prints the menu (AppKit shows it on screen above other apps for a moment), `GITBONSAI_MENU_SHOT=<png>` renders it, and `GITBONSAI_MENU_PICK=<title>` or `<title>/<title>` chooses an entry; `GITBONSAI_MENU_LIST=<row>` only prints the visible entries without opening the menu, after 1.5 s so that the detected rebase base is filled in.
- Sheets of commit actions are answered by `GITBONSAI_FORM=key=value;…` (name, branch, path, message, checked=0|1), `GITBONSAI_CONFIRM=1` and `GITBONSAI_SAVE_PATH=<file>`, and `GITBONSAI_SHEET_SHOT=<png>` renders the sheet.

Remotes and rebase:

- `GITBONSAI_TOOLBAR_LAYOUT=1` prints the Pull and Push badges (`↓n ↑n`, `-` hidden, `!` no upstream), the frame of every toolbar action button (`▾` for those with a menu) and the Pull and Push tooltips, to check that badges never move a button.
- `GITBONSAI_FETCH_MENU=1` prints the Fetch button's menu with each entry's git command without opening it, and `GITBONSAI_FETCH_PICK=<title>` runs an entry and prints the status line afterwards.
- `GITBONSAI_MENU_RUN=<row>:<title>` runs an entry of a history row's menu without opening the menu; `GITBONSAI_ONTO=<base>` chooses the old base of the interactive rebase sheet by name or revision when it opens, as picking it in the ref picker would.
- `GITBONSAI_BANNER_CLICK=continue|skip|abort` clicks a button of the rebase, cherry-pick, revert or merge banner with a real click and prints the banner before and after.
- `GITBONSAI_REBASE_SCRIPT=<step>;…` drives the interactive rebase sheet with real clicks, drags and keys once "Rebase <branch> interaktiv auf … …" opened it: `drag:<row>><gap>`, `click:<row>`, `key:<key>` (letter, `opt-up`, `opt-down`), `popup:<row>=<action>`, `subject:<row>=<text>`, `message:<text>` (`\n` for a new line), `base:<revision>` (the old base), `resize:<column>><points>` (drags a column edge over the rows), `toggle:update-refs|autostash`, `size:<width>x<height>`, `print`, `shot:<png>`, `start`, `cancel`. `GITBONSAI_REBASE_MENU=<row>,…` prints a row's interactive rebase entries with the reason a disabled one gives.
- `GITBONSAI_PRINT_SELECTION=<seconds>,…` prints whether the toast shows, the selected history row, whether it is HEAD and whether a diff covers the history after each delay; every toast is printed when it appears with its action in brackets.
- `GITBONSAI_REWORD_SCRIPT=<step>;…` edits a commit message in place in the detail panel with real clicks and keys: `select:<row>` (selects the row without a click), `menu` (the commit menu's "Nachricht bearbeiten"), `dblclick` (on the subject), `pencil`, `cmd-e` (the main menu entry's validation and action), `subject:<text>`, `body:<text>`, `key:<key>` (`escape`, `cmd-return`), `save`, `cancel`, `print` (log, selection, editor, status line), `shot:<png>`, `wait:<seconds>`.
- `GITBONSAI_EDIT_AMEND=<subject>` at an edit stop clicks "Commit ändern …" in the banner, types the subject into the commit form, clicks Amend and then Fortsetzen; `GITBONSAI_REBASE_UNDO=1` clicks "Rückgängig" in the status line (the question takes `GITBONSAI_CONFIRM=1`).
- `GITBONSAI_FETCH=<title>`, `GITBONSAI_PULL=<title>`, `GITBONSAI_PUSH=<title>` or `GITBONSAI_STASH=<title>` clicks the chevron of that toolbar split button with a real click, prints its menu (an empty title stops there), chooses the entry and prints the status line, the banner, the ahead/behind counts and the button frames afterwards; the first-push and upstream sheets take `GITBONSAI_FORM` (remote, name, upstream).
- `GITBONSAI_TOOLBAR_DEFAULT=Fetch|Pull|Push|Stash` clicks the main part of that split button with a real click, which runs the first enabled entry of its menu, and prints the status line, the banner and the ahead/behind counts afterwards.

Sidebar:

- `GITBONSAI_OPEN_PANEL=tags|stashes` opens that popover with a real press on its sidebar row and prints its entries; then `GITBONSAI_PANEL_FILTER=<text>` filters, `GITBONSAI_PANEL_SELECT=<n>` presses entry n and prints where the history went, `GITBONSAI_PANEL_SHOT=<png>` renders the list, and `GITBONSAI_PANEL_BUTTON=<title>` presses a button below it or `GITBONSAI_PANEL_MENU=<title>` runs an entry of the selected row's menu without opening it. Questions are answered like those of commit actions. With `GITBONSAI_PRINT_HISTORY` the history is also printed right before the button or menu action.
- For the Tags list the harness waits until every remote answered `ls-remote` and prints each tag's marks and tooltip; `GITBONSAI_PANEL_SCOPE=<title>` picks a filter scope such as "Nur lokal" first and `GITBONSAI_PANEL_SCROLL=<lines>` scrolls the list with a wheel event. After a button or menu action the harness samples the marks until the remotes answered anew, prints the fewest marked rows, the list and whether the popover is still open; `GITBONSAI_PANEL_SHOT_DURING=<png>` and `GITBONSAI_PANEL_SHOT_AFTER=<png>` render the list while the refresh runs and after it. A slow remote is simulated with `git config remote.origin.uploadpack <script that sleeps, then runs git-upload-pack>`.
- `GITBONSAI_PANEL_FRAMES=<seconds>` samples the frames of a panel's filter field, its scope arrow, its text, the counter and the busy slot from the moment the popover shows and prints them whenever they change, with whether the list was busy; `GITBONSAI_PANEL_FRAMES_SHOT=<prefix>` renders the list each time it turns busy or idle. Nothing may change while the remotes are asked.
- `GITBONSAI_SHEET_CLICK=confirm|cancel` shows confirmations as real sheets on the window instead of answering them and clicks that button with real events; it prints whether a popover is still open behind the sheet, and `GITBONSAI_SHEET_SHOT=<png>` renders the sheet.
- `GITBONSAI_SHEET_KEY=escape|return` with `GITBONSAI_FOREGROUND=1` shows forms and confirmations as real sheets and posts that key to the event queue once the sheet is up; it prints the focus, the buttons' keys, the button that ended the sheet and the field contents. `GITBONSAI_FORM` fills a form first, and `GITBONSAI_SHEET_FOCUS=message` focuses its multi-line message. The discard confirmation takes the key too.
- `GITBONSAI_TOOLBAR=Stash|Pop` presses that toolbar button and prints whether it was enabled; the "Stash mit Nachricht …" sheet takes `GITBONSAI_FORM=message=…;checked=0|1`.
- `GITBONSAI_TOOLBAR_HIGHLIGHT=1` prints when a split button shows pressed and what let it go (the menu closing or `popUp` returning).
- `GITBONSAI_TOAST_SHOT=<png>` renders the window once the first toast with an action shows; `GITBONSAI_TOAST_CLICK=<action>` then clicks that action ("Rückgängig", "Details", "Konflikte anzeigen") with a real click and prints the status line and the working tree.
- Failure sheets are printed with their actions in braces and not shown; `GITBONSAI_REPORT_SHOT=<png>` renders one with "Git-Ausgabe" open. `GITBONSAI_REPORT_CLICK=<button>` shows them as real sheets and clicks that button, `GITBONSAI_REPORT_DETAILS=1` first opens "Git-Ausgabe" with a click; the sheet's buttons and the output box's frame are printed.
- `GITBONSAI_SIDEBAR_SCROLL=<points>` scrolls the sidebar down and prints the left edge of its scroller next to the right edge of the status slot column; the capture does not draw scrollers, so these numbers show whether one covers the slot.
- `GITBONSAI_SIDEBAR_GUTTER=collapsed|expanded` prints the right edges of the sidebar rows, the status slot column and the counts with every section collapsed and expanded, under a legacy and an overlay scroller; the numbers stay the same in all four. The capture then shows the sections in the given state.
- `GITBONSAI_SIDEBAR_MENU_LIST=<subject>` prints a sidebar row's context menu without opening it (`branch:<name>`, `branch:origin/<name>`, `worktree:<folder>`), and `GITBONSAI_SIDEBAR_MENU_PICK=<title prefix>` runs one of its entries; `GITBONSAI_SIDEBAR_MENU=<subject>` right-clicks the row with a real event instead (the menu shows on screen for a moment); `GITBONSAI_NEW_BRANCH=plus|toolbar` opens the new-branch sheet with a real click on the Local plus or the toolbar's Branch button. Other sheets of these menus are answered with `GITBONSAI_FORM` (keys name, path, upstream, reason, checked) and `GITBONSAI_CONFIRM=1`.
- `GITBONSAI_SIDEBAR_MENU_PICK` together with `GITBONSAI_SIDEBAR_MENU` runs the entry after the real right-click, from the menu that row builds. `GITBONSAI_CHOICE=<button title prefix>` answers a question with several ways forward, such as the diverged branch after „<branch>“ pullen; without it the harness cancels. `GITBONSAI_PRINT_STATUS=<seconds>,…` prints the status line, the toolbar counts and the selected row after each delay.
- `GITBONSAI_NEW_BRANCH_SCRIPT=<step>;…` drives the open new-branch sheet with real clicks and keys: `click:name|picker|worktree|checkout|path|create|cancel`, `click:row:<n>` (entry n of the open ref picker), `type:<text>`, `key:return|escape|up|down|delete`, `print` (the form's state and the picker's entries) and `shot:<png>` (the sheet with the open picker); give it time with `GITBONSAI_CAPTURE_DELAY`.

Settings:

- `GITBONSAI_SETTINGS=general|git|appearance|fetch|avatars` opens the settings window on that section and captures it instead of the main window.
- `GITBONSAI_AUTO_FETCH=<seconds>` turns automatic fetching on for the run: on activation and when a tab becomes visible, and periodically at that interval unless it is 0. Each decision is printed; harness runs otherwise never fetch automatically.
- `GITBONSAI_AUTO_FETCH_STEPS=activate,tab,…` posts the app's activation or selects the next tab, one step every two seconds, and prints every tab's toolbar counts after each step.

Avatars (harness runs load none unless asked):

- `GITBONSAI_AVATARS=off|remote|gravatar` sets "Avatare laden" and its sources for the run; `GITBONSAI_AVATAR_CACHE=<folder>` keeps the disk cache there, an empty folder for a cold load; without it harness runs use a temporary folder.
- `GITBONSAI_AVATAR_LOG=1` prints every avatar request with status, host and path and a running number; `GITBONSAI_AVATAR_SWEEP=<rows>` pages the history down to that row, half a second per screen.

Command bar:

- `GITBONSAI_COMMAND_BAR=<step>;…` drives the command bar once the tab has loaded, half a second per step, then captures the window: `open` (⌘⇧P through the main menu), `type:<text>` and `key:down|up|return|escape|backspace` as real key events, `click:<row>`, `print` (step, field, every row with selection, context, reason and shortcut), `status` (branch, HEAD, upstream counts and status line), `wait:<seconds>`, `shot:<png>`. Each run starts without recently used commands. Editors, terminals and the Finder are not launched under the harness; the command prints the app and what it would open.
- `GITBONSAI_PRINT_MENU=1` prints the generated menu bar a second after loading, each item with shortcut and enabled state (with `GITBONSAI_NEW_TAB=1` for the empty tab); in a `GITBONSAI_COMMAND_BAR` script `menu` prints it, `shortcut:ctrl-cmd-s` presses a key equivalent through the main menu and `pick:Branch/Branch auschecken …` chooses an item; `settings` opens the settings window and makes it key and `windows` prints the visible windows, the key window and the tabs (a key window needs `GITBONSAI_FOREGROUND=1`).
- `GITBONSAI_PRINT_OPENERS=1` prints for every known terminal and editor whether it is installed and how it would open the tab's folder (document, URL scheme or its binary), then the editors and terminals the settings list and the default of each.
- Background runs draw the bar's glass as a matte panel, because rendering the views leaves everything around a glass view blank; with `GITBONSAI_FOREGROUND=1` `shot:` asks `screencapture` for the real window, which needs Screen Recording for the app.

Files, diffs and commits:

- `GITBONSAI_OPEN_FILE=<path>` with `GITBONSAI_OPEN_SOURCE=unstaged|staged|untracked` opens a file's diff (without a source: the file in the selected commit), and `GITBONSAI_HUNK_ACTION=<n>` stages or unstages hunk n; `GITBONSAI_WINDOW_WIDTH=<points>` resizes the window before the diff opens.
- `GITBONSAI_OPEN_ORIGINAL=<path>` passes the path before a rename or copy with `GITBONSAI_OPEN_FILE`, as the file lists do; `GITBONSAI_PRINT_DIFF_HEADER=1` prints the header's change letter, path and tooltip.
- `GITBONSAI_CLICK_DIFF_MODE=diff|file` clicks that half of the "Diff | Datei" toggle in the open diff with a real click and prints the numbers of the top and bottom line.
- `GITBONSAI_DIFF_NEXT=<n>` clicks the ↓ of the hunk navigation n times and prints the top line after each jump.
- `GITBONSAI_CLICK_DIFF_CLOSE=1` clicks the close button of the open diff with a real click and prints whether the diff is still shown.
- `GITBONSAI_DIFF_MODE=diff|file|remembered` starts the diff in that mode; harness runs otherwise start in "Diff", and `remembered` reads the choice an earlier harness run stored.
- `GITBONSAI_DIFF_INVISIBLES=1|0|remembered` starts the diff with or without invisible characters; harness runs otherwise start without them.
- `GITBONSAI_DIFF_OPTION=<title>` prints the diff options menu with each entry's state, chooses that entry without opening the menu and prints it again.
- `GITBONSAI_CLICK_FILE=<n>` clicks the n-th file in the detail panel with real mouse events and prints which diff opened.
- `GITBONSAI_FILE_KEYS=down,down,up` then presses arrow keys through the window and prints the first responder, the history row and the opened diff after each.
- `GITBONSAI_COMMIT_SUBJECT`, `GITBONSAI_COMMIT_BODY` (with `\n`), `GITBONSAI_AMEND=1` and `GITBONSAI_COMMIT_RUN=1` fill the commit form, tick amend and click the commit button.
- `GITBONSAI_CLICK_HUNK_DISCARD=<n>` clicks "Hunk verwerfen" of hunk n in the open diff, `GITBONSAI_HOVER_FILE=<n>` moves the mouse onto the n-th file row and `GITBONSAI_CLICK_FILE_DISCARD=<n>` clicks its discard button; the confirmation sheet is answered with `GITBONSAI_DISCARD_ANSWER=confirm|cancel` by a real click, or, without an answer, written to `GITBONSAI_SHEET_SCREENSHOT=<path>`.
- `GITBONSAI_FILE_MENU=<n>` prints the context menu of the n-th file row (⌥ alternates marked) without opening it on screen, and `GITBONSAI_FILE_MENU_PICK=<title>` chooses an entry; its questions are answered by `GITBONSAI_CONFIRM=1` and rendered by `GITBONSAI_SHEET_SHOT=<png>`.
- `GITBONSAI_CLICK_COMMIT_COPY=full|short` clicks the copy icon next to the commit SHA with a real click (⌥ held for `short`) and prints what landed on the harness's own pasteboard and the icon's state, and the frames of the button, its image, its line and the panel's content before the click, with the checkmark and after it; the capture shows the checkmark.
- `GITBONSAI_CLICK_PARENT=<n>` clicks the n-th parent link in the commit header with a real click and prints the selected commit before and after.
- `GITBONSAI_PRINT_CURSORS=1` prints the cursor that the copy icon, the parent links, the section actions and a file row with its action icon set when the pointer enters them.
- `GITBONSAI_NAVIGATE=<step>;…` drives navigation and comparisons with real clicks and keys, one step every `GITBONSAI_NAVIGATE_INTERVAL` seconds (default 1.5), and prints after each whether a diff is open, the selected commits, the comparison panel and the focus: `file:<n>`, `row:<n>`, `cmd:<n>`, `shift:<n>`, `key:up|down|return`, `parent:<n>`, `sidebar:<subject>`, `sidebar2:<subject>` (double click), `tags:<n>`, `search:<text>`, `git:<argument>,…` (runs git and refreshes like a write action), `stage:<path>`, `base` (the "seit gemeinsamer Basis" switch), `close`, `focus:history`, `tooltips:<row>` (the tooltip the row registers over labels, subject, author and date), `width:<points>`, `shot:<png>`.
- `GITBONSAI_DETAIL_TRACE=<n>[:<ms>]` presses ↓ n times in the history with real key events, <ms> apart (default 80), and prints every state of the detail panel that can reach the screen with its time, classified against the selected commit (complete, old-files, loading, empty, stale-header); `GITBONSAI_DETAIL_TRACE_SHOTS=<dir>` writes the panel as a PNG per state. `GITBONSAI_CAPTURE_DELAY` must cover the run.
