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

The app can render itself for checks without a human: `GITBONSAI_SCREENSHOT=/tmp/out.png swift run GitBonsaiApp /path/to/repo` writes the window to a PNG once loading has finished and quits. `GITBONSAI_APPEARANCE=light|dark` forces the appearance, `GITBONSAI_SELECT_ROW=n` selects a history row first. Several paths open as tabs; without a path the app restores the tabs of the last session. `GITBONSAI_NEW_TAB=1` shows the empty tab with the recently used repositories, `GITBONSAI_CLICK_TAB=n` switches tabs with a real click first. `GITBONSAI_CHECKOUT=<branch>` checks a local branch out before the capture and `GITBONSAI_SWITCH_WORKTREE=<folder name>` moves the tab to another worktree. Harness runs keep their session in their own defaults domain (`app.gitbonsai.harness`).
