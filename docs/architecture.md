# GitBonsai — Architektur

Siehe auch: [Feature-Überblick](feature-overview.md) · [Screens](screens.md) · [Flows](flows.md)

## 1. Schichten

| Schicht | Target | Abhängigkeiten | Verantwortung |
|---|---|---|---|
| Engine | `GitEngine` | Foundation | Prozess-Runner, Modelle, Parser, `Repository`-Fassade, Kommando-Log, Dateisystem-Watching |
| Layout | `GraphLayout` | `GitEngine` | Inkrementelles Lane-Layout für den Commit-Graphen; reine Funktionen über `Commit` |
| App | `GitBonsaiApp` | beide, AppKit, SwiftUI | View-Models, Fenster, Graph- und Diff-Rendering, Drag-and-drop, Settings |

Regeln: `GitEngine` und `GraphLayout` importieren weder AppKit noch SwiftUI. Jede Aktion der App entspricht genau einem git-Kommando, das im Kommando-Log erscheint. Nichts wird nachgebaut, was git selbst kann.

## 2. GitRunner

`GitRunner` ist ein Actor pro Repository-Pfad (bei Worktrees: ein Runner pro Worktree, da `git -C <worktree>` die Working-Tree-Sicht bestimmt).

### 2.1 Umgebung und Neutralisierung

| Variable / Option | Reads | Writes | Zweck |
|---|---|---|---|
| `GIT_TERMINAL_PROMPT=0` | ✅ | ✅ | Kein Hänger auf Credential- oder Passphrase-Prompts |
| `GIT_OPTIONAL_LOCKS=0` | ✅ | – | `status` und `log` nehmen keine Index-Locks, Reads stören keine laufenden Writes |
| `LC_ALL=C` | ✅ | ✅ | Stabile englische Fehlermeldungen und Datumsformate |
| `GIT_ASKPASS=<App-Helper>` | – | ✅ | Credential-Dialog der App für HTTPS-Push/Fetch, wenn kein Helper konfiguriert ist |
| `GIT_SSH_COMMAND` | – | ✅ | Nur gesetzt, wenn der Nutzer in den Settings einen eigenen Key wählt |
| `-c core.quotepath=off` | ✅ | ✅ | Unicode-Pfade unmaskiert |
| `-c color.ui=never` | ✅ | ✅ | Keine ANSI-Sequenzen in geparster Ausgabe |
| `-c log.showSignature=false` | ✅ | – | Keine GPG-Ausgabe in `log` |
| `-c diff.noprefix=false -c diff.mnemonicPrefix=false` | ✅ | – | Stabile `a/`/`b/`-Präfixe für den Diff-Parser |
| `-c core.pager=cat` | ✅ | ✅ | Kein Pager |

Aliase werden nie benutzt; jedes Kommando ist ein eingebautes git-Kommando mit vollem Namen.

### 2.2 Nebenläufigkeit

- **Reads** (`run`, `stream`) laufen parallel und unbegrenzt; sie sind durch `GIT_OPTIONAL_LOCKS=0` seiteneffektfrei.
- **Writes** (`runWrite`) laufen seriell pro Repository über eine interne Queue im Actor. Ein laufender Write blockiert neue Writes, nicht Reads.
- **Streams**: `stream(_:)` liefert `AsyncThrowingStream<Data, Error>` mit stdout-Chunks. Das Abbrechen der konsumierenden Task sendet `SIGTERM` an git; bei einem Exit ≠ 0 endet der Stream mit `GitError` inklusive vollständigem stderr.
- **Timeouts**: keine. Lange Operationen (Clone, Fetch) zeigen Fortschritt aus stderr (`--progress`) und sind abbrechbar.

### 2.3 Kommando-Log

Jeder Aufruf wird als `GitCommandLogEntry` (Argumente, Exit-Code, Dauer, stderr, gekürztes stdout) gespeichert, begrenzt auf die letzten 500 Einträge pro Runner. Das Log-Panel zeigt Reads grau, Writes schwarz, Fehler rot; ein Eintrag lässt sich als Shell-Zeile kopieren.

## 3. Kommandos und Formate

### 3.1 Log

```
git log --all --topo-order --parents --date=unix \
  --format=<Felder getrennt durch 0x1F, Record-Ende 0x1E> \
  [-n <limit>] [--skip <n>] [--grep=<text>] [--author=<text>] [-- <pfade>]
```

Felder in Reihenfolge: `%H`, `%P`, `%an`, `%ae`, `%at`, `%cn`, `%ce`, `%ct`, `%s`, `%b`. Der Record-Separator steht am Ende des Formats, deshalb kein `-z`. `LogParser.feed(_:)` ist inkrementell und liefert pro Chunk alle vollständigen Records; ein Rest wird gepuffert. `%b` darf Newlines und beliebige Bytes enthalten, deshalb Trennung über Steuerzeichen statt Zeilen.

Varianten: ohne `--all` für "nur aktueller Branch"; `--first-parent` für die Solo-Ansicht (V2); `-S<text>` / `-G<regex>` nur als explizite Aktion (Pickaxe diffst jeden Commit).

### 3.2 Refs

```
git for-each-ref --format='%(refname)%1F%(objecttype)%1F%(objectname)%1F%(*objectname)%1F%(HEAD)%1F%(upstream:short)%1F%(upstream:track)%1E' \
  refs/heads refs/remotes refs/tags refs/stash
```

`%(*objectname)` liefert bei annotierten Tags den Commit. `%(upstream:track)` wird zu `ahead`/`behind` geparst; `[gone]` ergibt `upstream` gesetzt und `ahead = behind = nil`.

### 3.3 Status

```
git status --porcelain=v2 -z --branch --untracked-files=all --ignored=no
```

Zeilentypen `#` (branch.oid, branch.head, branch.upstream, branch.ab), `1` (normal), `2` (rename/copy, zweiter NUL-Pfad), `u` (unmerged mit Konfliktart aus den XY-Codes), `?` (untracked), `!` (ignored, nur wenn angefordert). Submodule erkennt der Parser am `<sub>`-Feld `S...`.

### 3.4 Diff

```
git diff --no-color -p --no-ext-diff -M -z [--cached] [--] <pfad>
git diff --no-color -p --no-ext-diff -M <sha>^! -- <pfad>        # Commit-Diff
git diff --no-color -p --no-ext-diff -M <a> <b> -- <pfad>         # zwei Commits
```

Der Unified-Parser liefert `FileDiff` mit Hunks und Zeilen inklusive `\ No newline at end of file`. Hunk-Staging: Dateiheader + ein Hunk unverändert nach `git apply --cached --unidiff-zero=false -` (stdin). Unstage: `git apply --cached -R -`. Discard-Hunk: `git apply -R -`. Zeilen-Staging (V1) baut aus einem Hunk einen reduzierten Hunk mit korrigierten Zählern.

### 3.5 Worktrees

```
git worktree list --porcelain -z
git -C <worktree> status --porcelain=v2 --branch -z       # pro Worktree, parallel
git worktree add [-b <neu>] <pfad> <ref>
git worktree remove [--force] <pfad>
git worktree prune
```

### 3.6 Branches, Remotes, Tags

| Aktion | Kommando |
|---|---|
| Branch anlegen | `git branch <name> <start>` bzw. `git switch -c <name> <start>` |
| Checkout | `git switch <name>` / `git switch --detach <sha>` |
| Umbenennen, löschen | `git branch -m <alt> <neu>`, `git branch -d/-D <name>` |
| Upstream | `git branch --set-upstream-to=<remote>/<branch> <name>` |
| Fetch | `git fetch --prune --progress [<remote>]` |
| Pull | `git pull --ff-only` / `--rebase` / `--no-rebase` je nach Dialog |
| Push | `git push --progress [-u] <remote> <branch>:refs/heads/<branch>` ; Force nur als `--force-with-lease` |
| Remote | `git remote add/rename/remove/set-url` |
| Tag | `git tag [-a -m <msg>] [-s] <name> <sha>`, `git push <remote> refs/tags/<name>` |

### 3.7 Merge, Rebase, Cherry-pick, Reset, Stash

| Aktion | Kommando |
|---|---|
| Merge | `git merge [--no-ff|--ff-only|--squash] <quelle>`, Abbruch `git merge --abort` |
| Rebase | `git rebase [--onto <neu-basis>] <basis> [<branch>]`, `--continue/--skip/--abort` |
| Rebase mit Stack | `git rebase --update-refs <basis>` |
| Interaktiv | `GIT_SEQUENCE_EDITOR=<helper> git rebase -i <basis>`; der Helper ersetzt die Todo-Datei durch die von der App erzeugte Liste und beendet sich |
| Cherry-pick | `git cherry-pick [-x] <sha>…`, bei Merge-Commits nach Rückfrage `-m 1` |
| Revert | `git revert [-m 1] <sha>` |
| Reset | `git reset --soft/--mixed/--hard <sha>` |
| Stash | `git stash push [-u] [-m <msg>] [-- <pfade>]`, `git stash list --format=…`, `git stash show -p stash@{n}`, `pop/apply/drop` |

### 3.8 Konflikte

```
git diff --name-only --diff-filter=U -z
git show :1:<pfad>  :2:<pfad>  :3:<pfad>          # base, ours, theirs
git checkout --ours|--theirs -- <pfad>
git merge-file -p <ours> <base> <theirs>           # V1-Editor
git add -- <pfad>                                  # als gelöst markieren
```

Laufender Zustand aus `.git`-Dateien: `MERGE_HEAD`, `REBASE_HEAD`, `rebase-merge/`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`. Diese Dateien werden nur gelesen, nie geschrieben.

### 3.9 Suche, Blame, Historie

```
git log … --grep=<t> --author=<t> --since=<d> --until=<d> -- <pfad>
git log -S<t> | -G<regex>                          # explizit
git grep -n -z -I -- <muster>                      # Working Tree
git log --follow --format=… -- <pfad>              # Datei-Historie
git blame --porcelain [--] <pfad> [<sha>]          # Blame
```

## 4. Dateisystem-Watching und Refresh

- **Quellen**: FSEvents auf dem Working Tree (rekursiv, ohne `.git/`) und separat auf `.git/` (HEAD, `refs/`, `packed-refs`, `index`, `MERGE_HEAD`, `rebase-merge/`, `logs/HEAD`, `worktrees/*/HEAD`).
- **Klassifikation**: Änderung im Working Tree → Status-Refresh. Änderung an `HEAD`/`refs`/`packed-refs`/`logs/HEAD` → Refs- und Log-Refresh. Änderung an `index` → Status-Refresh. Zustandsdateien (`MERGE_HEAD` …) → Banner-Refresh.
- **Koalition**: Ereignisse werden 150 ms gesammelt; Bursts (z. B. `npm install`) verlängern das Fenster bis maximal 1 s. Pro Klasse läuft höchstens ein Refresh gleichzeitig; ein währenddessen eintreffendes Ereignis markiert "dirty" und löst nach Abschluss genau einen weiteren Refresh aus.
- **Eigene Writes**: Nach jedem `runWrite` wird der Refresh direkt angestoßen und die durch FSEvents gemeldeten Folgeereignisse werden für 300 ms ignoriert.
- **Fallback**: Polling alle 10 s, wenn FSEvents für ein Volume (Netzlaufwerk) nicht liefert.

## 5. Cache

Pro Repository eine SQLite-Datei unter `~/Library/Caches/app.gitbonsai/<hash-des-pfads>.sqlite`:

| Tabelle | Inhalt | Zweck |
|---|---|---|
| `commits` | SHA, Eltern, Autor, Daten, Subject, Body | Sofortige Anzeige beim Öffnen, bevor `git log` liefert |
| `layout` | SHA, Lane, Farbe, Kanten (Blob), Reihenfolge-Index, Hash der Ref-Menge | Layout ohne Neuberechnung, solange die Refs gleich sind |
| `meta` | Letzter HEAD, Ref-Hash, git-Version | Validierung |

Der Cache ist ein reiner Beschleuniger: Beim Öffnen werden gecachte Zeilen angezeigt, parallel läuft `git log`; weicht die neue Reihenfolge ab, wird ab der ersten Abweichung ersetzt. Ein Cache-Fehler führt nie zu einem Nutzerfehler, nur zu einem Neuaufbau.

## 6. Lazy-Graph-Pipeline

```
git log (stream) ─▶ LogParser.feed ─▶ GraphLayout.append ─▶ GraphStore (MainActor)
                                                                  │
                                                     NSTableView (virtualisiert)
                                                                  │
                                                     GraphRowView.draw(_:) mit CoreGraphics
```

1. `Repository.log` startet git und liefert `Commit`-Werte, sobald ein Record komplett ist; die ersten Commits sind nach wenigen Millisekunden da, weil `--topo-order` die Ausgabe streamt, auch wenn git intern den vollen Walk macht (deshalb `commit-graph` pflegen, siehe 3.1 und `Repository.writeCommitGraph`).
2. `GraphLayout` hält nur die aktiven Lanes (erwartete Eltern-SHAs pro Lane) und gibt pro Commit eine `GraphRow` mit Knoten-Lane, Farbe und Kanten zur nächsten Zeile zurück. Speicher pro Zeile ist konstant.
3. Der `GraphStore` (MainActor) sammelt Zeilen in Batches von 200 und meldet `insertRows` an die Tabelle; die Tabelle fragt nur sichtbare Zeilen ab.
4. `GraphRowView` zeichnet Lanes, Kanten und Knoten mit CoreGraphics; Labels (Refs, Subject, Autor, Datum) sind `NSTextField`-Zellen oder direkt gezeichneter Text für maximale Scroll-Leistung. Keine SwiftUI-View pro Commit.
5. Refs, Avatare und Worktree-HEADs kommen aus separaten Abfragen und werden über eine SHA→Dekoration-Map in die Zeilen gemischt; eine Änderung der Refs zeichnet nur betroffene Zeilen neu.
6. Die WIP-Zeile ist eine synthetische erste Zeile pro Worktree mit HEAD als Elternteil; sie erscheint nur bei `status`-Einträgen.

Lane-Farben sind stabil pro Strang: eine Lane behält ihre Farbe von der Entstehung (Fork) bis zur Vereinigung (Merge).

## 7. Nebenläufigkeitsmodell

| Ebene | Isolation | Inhalt |
|---|---|---|
| `GitRunner` | Actor pro Worktree-Pfad | Prozesse, Write-Queue, Kommando-Log |
| `Repository` | `Sendable` Fassade | Startet Reads auf dem Runner, liefert Streams und Werte |
| `RepositoryWatcher` | eigener Actor | FSEvents, Koalition, löst Refreshes aus |
| `RepositoryModel` | `@MainActor @Observable` | Refs, Status, Worktrees, laufender Zustand, Graph-Store; einzige Quelle für Views |
| Views | MainActor | SwiftUI für Chrome, AppKit über `NSViewRepresentable` für Graph, Diff, Konflikt-Editor |

Jede Operation ist eine `Task` mit Abbruchmöglichkeit; Streams werden bei Repository-Wechsel oder Fensterschluss abgebrochen. Kein `DispatchQueue`, keine Locks außerhalb des Runners.

## 8. Fehlerbehandlung

- `GitError` trägt Argumente, Exit-Code und das vollständige stderr. Die UI zeigt immer den ersten stderr-Satz als Titel und das vollständige Kommando plus stderr aufklappbar.
- Bekannte Muster werden erkannt und bekommen Aktionen: `CONFLICT` → Konflikt-Banner; `non-fast-forward` → Dialog mit Fetch/Pull; `Authentication failed` → Hinweis auf Credential-Helper und Settings; `index.lock` → Retry-Button; `not a git repository` → Repo schließen.
- Hooks: stdout/stderr der Hooks ist Teil des Kommando-Logs; ein abgelehnter Commit zeigt die Hook-Ausgabe im Commit-Panel.
- Nie ein stiller Fehler: Jede fehlgeschlagene Operation ist im Kommando-Log rot markiert.

## 9. Performance-Budgets (als Tests)

| Metrik | Budget | Testrepo |
|---|---|---|
| Fenster bis erste 300 Commits sichtbar | < 100 ms (Cache) / < 300 ms (ohne Cache) | 100k synthetisch |
| `GraphLayout` für 100k Commits | < 2 s | 100k synthetisch |
| `LogParser` Durchsatz | > 200k Commits/s | 100k synthetisch |
| Status-Refresh bei 10k geänderten Dateien | < 200 ms Parser, UI bleibt bedienbar | Fixture |
| Scroll über 100k Zeilen | 60 fps, kein Layout im Draw-Pfad | 100k synthetisch, Instruments |
| Speicher 100k Commits geladen | < 150 MB | 100k synthetisch |

`scripts/make-synthetic-repo.sh` erzeugt das Benchmark-Repo.

## 10. Verifikations-Harness für agentengetriebene UI-Arbeit

Ziel: Eine Schleife, die so nah wie möglich an Browser-Tools liegt, ohne Xcode-GUI.

| Baustein | Umsetzung |
|---|---|
| Snapshot-Tests | `swift-snapshot-testing` für Graph-Zeilen, Diff-Zeilen, Sidebar-Zustände; Referenzbilder liegen unter `Tests/__Snapshots__` |
| Debug-URL-Scheme | `gitbonsai://debug/open?repo=<pfad>&select=<sha>&panel=wip` bringt die laufende App deterministisch in einen Zustand; danach `screencapture -l <windowid>` |
| Accessibility-Dump | Alle Elemente tragen `accessibilityIdentifier`; ein Dump über AXUIElement liefert den Zustand als Text, analog zum Accessibility-Tree im Browser |
| Fixture-Repos | `Tests/GitEngineTests/FixtureRepo.swift` baut Repos zur Laufzeit; `scripts/make-synthetic-repo.sh` für Größe |
| Budgets | `swift test --filter Performance` schlägt bei Überschreitung fehl |

Jede UI-Aufgabe bekommt ein Screenshot- oder Snapshot-Akzeptanzkriterium, damit der Agent sie ohne Menschen abschließen kann; nur Scroll-Gefühl und Interaktionsdetails werden von Hand abgenommen.
