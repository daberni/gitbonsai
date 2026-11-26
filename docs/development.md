# Developing GitBonsai

How to build, run, test, measure and package GitBonsai. The engine design is in [architecture.md](architecture.md), the git command behind every operation in [git-operations.md](git-operations.md), and the working rules for contributors and agents in [AGENTS.md](../AGENTS.md).

## Build and run

```bash
swift build
swift test
swift run GitBonsai /path/to/repo
```

`GitBonsai` is the app; tests reach it through `@testable import GitBonsai`.

## Benchmarks

`scripts/make-synthetic-repo.sh bench/synthetic 100000` creates a 100k-commit repository with branches and merges for checks on a large history. `swift run -c release Benchmarks` measures the performance budgets and prints median, min and spread next to each budget; `--filter <text>` picks benchmarks by name, `--json <path>` writes the results, and `--compare Benchmarks/baseline.json` fails when a median is more than 20 % slower than the baseline (`--threshold`; changes under 1 ms, `--min-delta`, never count). The baseline comes from a developer machine, so compare only locally. Laying out and searching 100k commits run in process against `GraphLayout` and `GitEngine`; so do opening a 100k-line file (`text.open100k`: decoding and indexing its lines) and colouring its first 300 lines (`text.highlight100k.first300`: tree-sitter parse plus query) against `TextViewerModel`. Opening a 100k-commit repository until 300 rows are laid out and the file list of a commit with 10,000 files are measured in the app: the benchmark builds `GitBonsai Dev.app`, launches it isolated through `scripts/launch-dev.sh` once per iteration and reads the `repository.open` and `files.load` signpost intervals the app emits from `log stream --signpost`, so the numbers include a real launch's cold caches. Fixture repositories are generated once into `.build/benchmark-fixtures`. CI runs the benchmarks nightly and on manual dispatch with `--engine-only` (its runners have no window server), apart from the tests, and only uploads the JSON. To refresh the baseline after an intended change, run `swift run -c release Benchmarks --json Benchmarks/baseline.json`.

## App bundle and releases

```bash
scripts/make-app-bundle.sh
open ".build/app/GitBonsai Dev.app"
```

The script builds the `GitBonsai` release binary and assembles `GitBonsai Dev.app` (bundle id `app.gitbonsai.dev`, its own defaults, macOS 26.0 or later) in `.build/app`, or in the directory given as its argument; `--release` builds `GitBonsai.app` with `app.gitbonsai` instead. Signing, notarization, packaging and the GitHub workflows are in [docs/release.md](release.md). It compiles the app icon `docs/design/app-icon/AppIcon.icon` with `actool` into `Assets.car` (the layered icon macOS 26 renders in every appearance) and writes a classic `AppIcon.icns` with 16–512 pt at @1x and @2x for older surfaces, then signs the bundle (ad hoc unless `GITBONSAI_SIGN_IDENTITY` is set). It needs Xcode for `actool`.

## Profiling and logs

Long-running work shows as signpost intervals in Instruments' Points of Interest (subsystem `app.gitbonsai`): `repository.open` (until the first 300 rows), `history.load`, `history.refresh`, `diff.load`, `files.load` (until the list draws), `fetch`, `pull`, `push`, `clone`, `rebase`, `rebase.interactive`, `search`, `discovery`, `avatar.lookup`, `commitGraph.write`, `textViewer.highlight` (parsing a file for syntax colours). Launch with `scripts/launch-dev.sh --foreground` and attach Instruments to `GitBonsai Check`, or read them with `/usr/bin/log stream --signpost --predicate 'subsystem == "app.gitbonsai"'`. Every git call writes one line to the unified log (category `git`): the subcommand, duration and exit code, and as private data its arguments, folder and on failure the start of stderr; `log stream --level debug --predicate 'subsystem == "app.gitbonsai"'` shows them with the app's other traces.

## Tests and verification

Views are checked without a window on screen: `SnapshotTests` render the main screens off screen in light and dark (`Tests/GitBonsaiTests/Snapshot.swift`) and compare them with reference PNGs in `Tests/__Snapshots__`, which stay on the machine and are not in the repository. The first run records a missing reference and prints where it went; later runs compare against it. Delete the folder to record anew after an intended change or an OS update; on another machine or OS build than the one in `__Snapshots__/machine.txt` the comparison is skipped. Load times and relative dates are blanked before the comparison. Look at every newly recorded reference before relying on it. Logic (menus, use cases, loading) is covered by unit tests against fixture repositories, which answer the app's questions through an injected `Prompting`.

Changes are checked in the real app with a GUI tool that reads the Accessibility tree and takes screenshots:

```bash
scripts/launch-dev.sh --appearance dark
```

`scripts/launch-dev.sh` builds `GitBonsai Dev.app` and launches a copy of it isolated: a throwaway home for its caches, avatar cache and git configuration, a defaults domain of its own (the preferences daemon ignores a changed home, so the copy gets its own bundle identifier), and a generated repository unless one is given. It starts in the background without taking the keyboard focus; `--foreground` brings it to the front for checks that need real mouse events. `--appearance light|dark` sets the app's own appearance preference (AppleInterfaceStyle cannot force light on a dark system), `--language en|de` passes the system's launch argument, `--default key=value` presets a preference, `--no-build` reuses the last bundle. It prints the process id, the repository, the home and the command that shows the app's traces (`log stream`, subsystem `app.gitbonsai`); the home and the defaults domain are removed when the app quits.
