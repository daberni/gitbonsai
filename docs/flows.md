# GitBonsai — Flows

Siehe auch: [Feature-Überblick](feature-overview.md) · [Architektur](architecture.md) · [Screens](screens.md)

Jeder Flow nennt Vorbedingungen, Schritte mit dem ausgeführten git-Kommando und dem UI-Feedback, und die Fehlerfälle. Alle Kommandos laufen mit der Umgebung aus [Architektur › GitRunner](architecture.md#2-gitrunner) und erscheinen im Kommando-Log.

## 1. Repository öffnen

Vorbedingung: Ordner ist ein Repository oder liegt in einem.

1. Nutzer wählt Ordner (⌘O, Drag auf Fenster, zuletzt verwendet). `git rev-parse --show-toplevel --git-common-dir --abbrev-ref HEAD` bestimmt Wurzel, `.git`-Verzeichnis und Branch. UI: Fenster mit Titel, Sidebar-Skelett.
2. Cache wird gelesen; vorhandene Zeilen erscheinen sofort im Graph.
3. Parallel: `git for-each-ref …` (Sidebar füllt sich), `git status --porcelain=v2 -z --branch --untracked-files=all` (WIP-Zeile), `git worktree list --porcelain -z` (Worktrees-Abschnitt), `git log --all --topo-order …` gestreamt (Graph ersetzt Cache ab der ersten Abweichung).
4. FSEvents-Watcher startet. Bei fehlender `commit-graph`-Datei und > 10 000 Commits läuft im Hintergrund `git commit-graph write --reachable`.
5. Optional Auto-Fetch nach Einstellung.

Fehler: kein Repository → Dialog "Kein Git-Repository" mit "Init hier"; git-Version < 2.38 → Banner mit Hinweis auf Settings › Git; Repo auf Netzlaufwerk ohne FSEvents → Polling-Hinweis im Log.

## 2. Commit mit Datei- und Hunk-Staging

Vorbedingung: Working Tree hat Änderungen; kein laufender Merge mit Konflikten.

1. Klick auf WIP-Zeile öffnet Working-Directory-Tab mit Unstaged/Staged aus dem letzten Status.
2. Datei stagen: Hover-Button oder S. `git add -- <pfad>`; gelöschte Datei: `git rm --cached -- <pfad>` bzw. `git add -A -- <pfad>`. Unstage: `git restore --staged -- <pfad>`. "Alle": `git add -A` / `git restore --staged .`. UI: Datei wechselt die Liste sofort (optimistisch), Status-Refresh bestätigt.
3. Hunk stagen: Datei auswählen, Diff-Tab zeigt `git diff --no-color -p --no-ext-diff -M -z -- <pfad>`. Button "Stage hunk" sendet Dateiheader + Hunk per stdin an `git apply --cached -`. Unstage: `git diff --cached … -- <pfad>` und `git apply --cached -R -`. Discard: Dialog, dann `git apply -R -`. UI: Hunk verschwindet aus der Seite, Diff lädt neu.
4. Subject und Body eingeben; Zähler färbt ab 50/72 Zeichen. Template aus `commit.template` vorbefüllt.
5. ⌘⏎: `git commit -F -` (Nachricht per stdin, erhält Zeilenumbrüche), mit Signing nach Konfiguration (`-S` nur, wenn in Settings aktiv und nicht schon `commit.gpgsign`). UI: neuer Commit erscheint oben im Graph, WIP-Zeile schrumpft oder verschwindet, Formular leert sich.

Fehler: Hook lehnt ab → Commit-Panel zeigt Hook-Ausgabe, Nachricht bleibt erhalten; `git apply` scheitert (Datei zwischenzeitlich geändert) → Diff lädt neu, Hinweis "Datei hat sich geändert"; leere Nachricht → Button deaktiviert; Signing-Fehler → stderr mit Link zu Settings › Git.

## 3. Fetch, Pull, Push

Vorbedingung: Remote konfiguriert; für Pull/Push ein Upstream.

1. **Fetch** (⌘⇧F): `git fetch --prune --progress [<remote>]`. UI: Spinner in der Toolbar, Fortschritt aus stderr im Log, danach Refs-Refresh; Behind-Badges aktualisieren sich.
2. **Pull** (⌘⇧L): Standard `git pull --ff-only`; Dropdown bietet `--rebase` und `--no-rebase`. UI: bei ff-only-Fehler "Branches sind auseinandergelaufen" Dialog mit Rebase/Merge/Abbrechen.
3. **Push** (⌘⇧P): `git push --progress <remote> <branch>:refs/heads/<branch>`; ohne Upstream Dialog "Upstream setzen" → `-u`. Force nur über Dropdown "Force push (with lease)" mit Dialog → `--force-with-lease`. UI: Ahead-Badge verschwindet, Remote-Label springt im Graph.

Fehler: Auth-Fehler → Dialog mit stderr und Hinweis Credential-Helper/SSH-Agent; `non-fast-forward` → Dialog mit "Fetch und ansehen"; Netzwerkfehler → Retry-Button; Push abgelehnt durch Hook/Branch-Protection → stderr vollständig.

## 4. Branch anlegen und wechseln

1. ⌘B oder Kontextmenü "Branch hier erstellen" am Commit. Sheet: Name (validiert mit `git check-ref-format --branch <name>`), Start-Ref (vorbelegt HEAD oder Commit), Checkbox "Auschecken", Checkbox "Als Worktree anlegen".
2. Anlegen: `git branch <name> <start>`; mit Auschecken `git switch -c <name> <start>`; als Worktree siehe Flow 10.
3. Checkout eines bestehenden Branches: Doppelklick in Sidebar oder ⏎ im Graph → `git switch <name>`; Remote-Branch → `git switch -c <name> --track <remote>/<name>`; Commit → `git switch --detach <sha>` mit Hinweis "Detached HEAD".
4. UI: HEAD-Label springt, Sidebar markiert, WIP-Zeile wechselt den Elternteil.

Fehler: lokale Änderungen kollidieren → Dialog "Änderungen stashen und wechseln" (`git stash push -u`, `git switch`, `git stash pop`) oder Abbrechen; Name existiert → Inline-Validierung; Branch in anderem Worktree ausgecheckt → kein Dialog, der Tab wechselt direkt in diesen Worktree (ein Branch kann nur einmal ausgecheckt sein, der Wechsel ändert nichts am Repository).

## 5. Merge per Drag-and-drop mit Ghost-Preview (V1)

Vorbedingung: Quelle ist ein Branch-Label, Ziel ist ein anderes Branch-Label (lokal oder remote); keine laufende Operation.

1. Drag beginnt am Label `feature/x`. Sofort: Graph-Layout wird eingefroren (kein Refresh, keine Nachladung, keine Zeilen-Einfügung), Watcher-Ereignisse werden gepuffert.
2. Während des Drags: Overlay-Layer zeichnet über dem Graphen. Lanes von Quelle und Ziel behalten volle Deckkraft, alle anderen Zeilen und Lanes werden auf 35 % gedimmt. Hover über einem gültigen Ziel-Label `main` zeigt einen **Ghost-Merge-Knoten** (gestrichelt) eine halbe Zeilenhöhe über der Ziel-Spitze mit gestrichelten Kanten zu beiden Eltern, und einen Tooltip `git merge feature/x` (mit ⌥: `git rebase main feature/x`). Ungültige Ziele (gleicher Branch, Commit statt Label bei Branch-Drag) zeigen das Verbotssymbol. Auto-Scroll nur am oberen/unteren Rand nach 400 ms Verweildauer.
3. Drop auf `main`: Popover mit Optionen "Merge (ff wenn möglich)", "Merge-Commit erzwingen (--no-ff)", "Squash", "Rebase feature/x auf main", "Abbrechen". Standardwahl per ⏎.
4. Ausführung: ist `main` nicht ausgecheckt, kommt zuerst `git switch main` (mit Stash-Dialog wie Flow 4), dann `git merge [--no-ff|--squash] feature/x`. Overlay verschwindet, Layout wird aufgetaut, gepufferte Ereignisse lösen einen Refresh aus; der echte Merge-Commit erscheint.
5. Esc während des Drags oder Drop außerhalb bricht ohne Kommando ab.

Fehler: Konflikte → Banner "Merge mit 2 Konflikten" (Flow 8); Quelle bereits enthalten → Hinweis "Bereits aktuell", kein Commit; Working Tree dirty und Ziel-Checkout nötig → Stash-Dialog.

## 6. Rebase per Drag mit ⌥ (V1)

1. Drag eines Branch-Labels mit gehaltener ⌥-Taste (oder ⌥ während des Drags drücken). Ghost zeigt die Commits der Quelle, die nicht im Ziel enthalten sind (`git rev-list --count ziel..quelle` wird beim Drag-Start berechnet), als gestrichelte Kopien linear über der Ziel-Spitze; die ursprüngliche Lane wird halbtransparent.
2. Tooltip `git rebase main feature/x`. Drop → Popover "Rebase", bei Branches, die auf Zwischen-Commits zeigen, Checkbox "Abhängige Branches mitziehen (--update-refs)".
3. Ausführung: `git rebase [--update-refs] main feature/x` (Checkout der Quelle ist implizit). Layout wird aufgetaut.

Fehler: Konflikte → Banner mit Schritt n/m und Fortsetzen/Überspringen/Abbrechen (`git rebase --continue/--skip/--abort`); veröffentlichte Commits würden umgeschrieben (Upstream enthält sie) → Warnung vor dem Start.

## 7. Cherry-pick per Drag (V1)

1. Drag einer Commit-Zeile (oder Mehrfachauswahl) auf ein Branch-Label. Ghost-Knoten über der Ziel-Spitze, Tooltip `git cherry-pick a1b2c3f`. Merge-Commits als Quelle zeigen das Verbotssymbol; mit ⌥ wird `-m 1` angeboten.
2. Drop → bei nicht ausgechecktem Ziel erst `git switch <ziel>` (Stash-Dialog), dann `git cherry-pick [-x] <sha>…` in chronologischer Reihenfolge.
3. UI: neue Commits erscheinen auf dem Ziel-Branch; Auswahl springt auf den letzten.

Fehler: Konflikt → Banner "Cherry-pick mit Konflikten", Fortsetzen (`git cherry-pick --continue`), Überspringen, Abbrechen; leerer Commit → Dialog "Leeren Commit behalten?" (`--allow-empty` oder `--skip`).

## 8. Konflikte lösen (MVP)

Vorbedingung: `.git/MERGE_HEAD`, `rebase-merge/` oder `CHERRY_PICK_HEAD` existiert; `git status` liefert `u`-Einträge.

1. Banner erscheint; Working-Directory-Tab listet Konflikt-Dateien rot mit Art (`git status --porcelain=v2` XY-Codes: `UU` both modified, `AA` both added, `DU`/`UD` deleted by us/them, `AU`/`UA` added by us/them, `DD` both deleted).
2. Pro Datei eine Entscheidung: **Ours** → `git checkout --ours -- <pfad>` und `git add -- <pfad>`; **Theirs** → `git checkout --theirs -- <pfad>` und `git add`; **Im Editor öffnen** → Datei mit Markern im externen Editor, nach dem Speichern Button **Als gelöst markieren** → `git add -- <pfad>`; bei Lösch-Konflikten **Datei behalten** (`git add`) oder **Löschen** (`git rm -- <pfad>`).
3. Der Diff-Tab zeigt die Datei mit Markern (`<<<<<<<`, `=======`, `>>>>>>>`) farbig; der Zähler im Banner zählt herunter.
4. Alle gelöst → **Fortsetzen**: Merge `git commit --no-edit` (Nachricht aus `MERGE_MSG`, editierbar im Working-Directory-Tab); Rebase `git rebase --continue` mit `GIT_EDITOR=true`; Cherry-pick `git cherry-pick --continue`.
5. **Abbrechen** → `git merge --abort` / `git rebase --abort` / `git cherry-pick --abort` nach Dialog.

Fehler: Datei nach "Als gelöst markieren" enthält noch Marker → Warnung mit "Trotzdem markieren"; `git add` scheitert wegen Lock → Retry.

## 9. Stash und Pop

1. ⌘⇧S oder Toolbar: Sheet mit Nachricht, Checkbox "Untracked einschließen" (vorausgewählt), optional "Nur ausgewählte Dateien" aus dem Working-Directory-Tab. Kommando: `git stash push -u [-m <msg>] [-- <pfade>]`. UI: WIP-Zeile verschwindet, Stash erscheint in der Sidebar.
2. Auswahl eines Stashes zeigt `git stash show -p --include-untracked stash@{n}` im Detail-Panel.
3. **Pop**: `git stash pop stash@{n}`; **Apply**: `git stash apply stash@{n}`; **Drop**: Dialog, `git stash drop stash@{n}`; **Branch aus Stash**: `git stash branch <name> stash@{n}`.

Fehler: Pop mit Konflikt → Banner "Stash-Konflikt", Stash bleibt erhalten, Lösung wie Flow 8, danach Hinweis "Stash manuell droppen"; nichts zu stashen → Button deaktiviert.

## 10. Worktree anlegen und wechseln

Vorbedingung: Branch ist in keinem anderen Worktree ausgecheckt.

1. "+" im Worktrees-Abschnitt, ⌘⇧W oder Kontextmenü eines Branches. Sheet: Branch (bestehend / neu ab Start-Ref), Pfad (Standard `../<repo>-<branch>`), Checkbox "Nach dem Anlegen wechseln".
2. Anlegen: `git worktree add <pfad> <branch>` oder `git worktree add -b <neu> <pfad> <start>`. UI: Fortschritt (Checkout kann bei großen Repos dauern), neuer Eintrag in der Sidebar.
3. Wechseln: Doppelklick → das Fenster bindet `Repository` auf den Worktree-Pfad: eigener `GitRunner`, `git status` und Watcher für den Worktree; der Graph bleibt (gemeinsames `.git`), die WIP-Zeile und der HEAD-Marker wechseln. Titel zeigt `repo › worktree`.
4. Jeder Worktree in der Sidebar zeigt laufend `git -C <pfad> status --porcelain=v2 --branch -z` (parallel, gedrosselt auf einen Refresh pro Worktree und 2 s).
5. Entfernen: Kontextmenü → `git worktree remove <pfad>`; bei dirty zweite Bestätigung → `--force`. Prune: `git worktree prune`.

Fehler: Pfad existiert und ist nicht leer → Inline-Fehler; Branch ausgecheckt in anderem Worktree → Hinweis mit "Dorthin wechseln"; Worktree-Ordner fehlt (prunable) → grauer Eintrag mit "Prune".

## 11. Interaktives Rebase (V1)

Vorbedingung: Ziel-Basis ist ein Vorfahre von HEAD; Working Tree sauber (sonst Stash-Dialog).

1. Kontextmenü "Rebase interaktiv ab hier…" am Basis-Commit. Sheet mit Commits `basis..HEAD` (aus `git log --reverse --format=… basis..HEAD`), Aktionen pick/reword/squash/fixup/drop, Umsortieren per Drag, Subject-Feld bei reword, Vorschau rechts.
2. **Rebase starten**: App schreibt die Todo-Liste in eine Temp-Datei; Kommando `GIT_SEQUENCE_EDITOR="<helper> <todo-datei>" GIT_EDITOR=true git rebase -i [--update-refs] <basis>`. Der Helper kopiert die Todo-Datei über die von git angelegte Datei. Reword-Nachrichten werden über `GIT_EDITOR=<helper>` mit vorbereiteten Nachrichten je Schritt geliefert.
3. UI: Banner zeigt Schritt n/m; bei Erfolg lädt der Graph neu, Auswahl springt auf den neuen HEAD.

Fehler: Konflikte → Flow 8 mit Fortsetzen/Überspringen/Abbrechen; Umschreiben veröffentlichter Commits → Warnung vor dem Start mit Anzahl betroffener Commits; `drop` aller Commits → Dialog "Branch wird auf die Basis zurückgesetzt".

## 12. Commits suchen

1. ⌘F fokussiert die Filterleiste. Freitext ab 2 Zeichen mit 250 ms Debounce startet `git log --all --format=%H --grep=<text> -i` (nur SHAs, gestreamt); ein neuer Tastendruck bricht den laufenden Prozess ab.
2. Treffer-SHAs werden in eine Menge gesammelt; der Graph dimmt Nicht-Treffer, ↑↓ springt zwischen Treffern, der Zähler zeigt "17 Treffer". Bei Repos mit > 50 000 Commits läuft die Suche erst auf den bereits geladenen Commits (sofort) und dann vollständig über git.
3. Chips `author:`, `path:`, `since:`, `until:` ergänzen `--author`, `-- <pfad>`, `--since`, `--until`. `sha:` prüft `git rev-parse --verify <prefix>^{commit}` und springt direkt.
4. "Inhalt (Pickaxe)"-Modus: Eingabe und Button "Suchen" → `git log --all --format=%H -S<text>` oder `-G<regex>`, mit Spinner und Abbrechen, weil jeder Commit gedifft wird.

Fehler: ungültige Regex → Inline-Fehler aus stderr; Suche länger als 5 s → Hinweis "Große Historie, Pickaxe läuft weiter…" mit Abbrechen.

## 13. Amend

1. Working-Directory-Tab, Checkbox "Amend": Subject und Body werden aus `git log -1 --format=%B` geladen; Staged-Änderungen werden eingeschlossen.
2. ⌘⇧⏎ oder Commit-Button "Amend": `git commit --amend -F -`. Ohne Staged-Änderungen und ohne Textänderung ist der Button deaktiviert.
3. UI: oberster Commit wird ersetzt (neuer SHA), Auswahl folgt.

Fehler: Commit ist bereits gepusht (Upstream enthält ihn) → Warnung "Erfordert Force-Push" vor dem Amend; Hook-Ablehnung wie Flow 2.

## 14. Wiederherstellung über Reflog (V2)

GitBonsai hat keinen eigenen Undo-Stack; git merkt sich jede HEAD-Bewegung selbst.

1. Menü Repository › Reflog… zeigt `git reflog --format=%H%1F%gd%1F%gs%1F%ct%1E` als Liste: Aktion (commit, checkout, rebase, reset …), Zeit, Subject.
2. Auswahl zeigt den Commit im Detail-Panel. Aktionen: **Branch hier erstellen** (`git branch <name> <sha>`), **Aktuellen Branch hierher zurücksetzen** (Dialog, `git reset --hard <sha>` oder `--soft`), **Cherry-pick**.
3. Typische Fälle: versehentlicher Reset, gelöschter Branch (Eintrag "checkout: moving from <branch>"), kaputter Rebase (`HEAD@{n}` vor "rebase (start)").

Fehler: Objekte bereits durch `gc` entfernt → Hinweis "Commit nicht mehr vorhanden"; dirty Working Tree bei `--hard` → Stash-Dialog.
