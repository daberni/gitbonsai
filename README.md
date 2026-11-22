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

The app can render itself for checks without a human: `GITBONSAI_SCREENSHOT=/tmp/out.png swift run GitBonsaiApp /path/to/repo` writes the window to a PNG once loading has finished and quits. `GITBONSAI_APPEARANCE=light|dark` forces the appearance, `GITBONSAI_SELECT_ROW=n` selects a history row first. Several paths open as tabs; without a path the app restores the tabs of the last session. `GITBONSAI_NEW_TAB=1` shows the empty tab with the recently used repositories, `GITBONSAI_CLICK_TAB=n` switches tabs with a real click first. `GITBONSAI_DRAG_TAB=from:to` drags a tab onto another tab's place with real mouse events and prints the resulting order. `GITBONSAI_CHECKOUT=<branch>` checks a local branch out before the capture and `GITBONSAI_SWITCH_WORKTREE=<folder name>` moves the tab to another worktree. `GITBONSAI_GRAPH_WIDTH=<points>` sets the width of the graph column and `GITBONSAI_GRAPH_SCROLL=<points>` scrolls the graph sideways. `GITBONSAI_SIDEBAR_SCROLL=<points>` scrolls the sidebar down and prints the left edge of its scroller next to the right edge of the status slot column; the capture does not draw scrollers, so these numbers show whether one covers the slot. `GITBONSAI_DRAG_GRAPH_TO=<points>` drags the boundary between graph and commit over the rows with real mouse events and prints the resulting width. `GITBONSAI_HIDDEN_COLUMNS=label,sha` hides columns (label, graph, author, sha, date). `GITBONSAI_OPEN_FILE=<path>` with `GITBONSAI_OPEN_SOURCE=unstaged|staged|untracked` opens a file's diff (without a source: the file in the selected commit), `GITBONSAI_HUNK_ACTION=<n>` stages or unstages hunk n, and `GITBONSAI_CAPTURE_DELAY=<seconds>` waits longer before the capture. `GITBONSAI_CLICK_FILE=<n>` clicks the n-th file in the detail panel with real mouse events and prints which diff opened. `GITBONSAI_COMMIT_SUBJECT`, `GITBONSAI_COMMIT_BODY` (with `\n`), `GITBONSAI_AMEND=1` and `GITBONSAI_COMMIT_RUN=1` fill the commit form, tick amend and click the commit button. `GITBONSAI_CLICK_HUNK_DISCARD=<n>` clicks "Hunk verwerfen" of hunk n in the open diff, `GITBONSAI_HOVER_FILE=<n>` moves the mouse onto the n-th file row and `GITBONSAI_CLICK_FILE_DISCARD=<n>` clicks its discard button; the confirmation sheet is answered with `GITBONSAI_DISCARD_ANSWER=confirm|cancel` by a real click, or, without an answer, written to `GITBONSAI_SHEET_SCREENSHOT=<path>`. Harness runs keep their session in their own defaults domain (`app.gitbonsai.harness`).
