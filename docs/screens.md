# GitBonsai — Screens

Siehe auch: [Feature-Überblick](feature-overview.md) · [Architektur](architecture.md) · [Flows](flows.md)

Designs: [Design-Sprache und Vollbild-Designs](design/README.md)

Phasen: **MVP** täglich nutzbar, **V1** vollständiger Alltagsclient. Kürzel folgen macOS-Konventionen (⌘ Command, ⌥ Option, ⇧ Shift, ⌃ Control).

## 0. Entscheidungen aus der Design-Review (2026-11-22)

Diese Punkte gelten vor allem, was weiter unten noch anders beschrieben ist; die Vollbild-Designs und das Brand-Book ([design/design-language.md](design/design-language.md)) sind maßgeblich.

- **Diff in der History-Spalte**: Eine Datei auswählen (Commit oder Working Directory) ersetzt den Graph durch ihren Diff; Hunk-Staging passiert dort. Das Detail-Panel enthält nie einen Diff.
- **Detail-Panel ohne Umschalter**: Es folgt der Auswahl in der History (Commit, Working Directory, Stash).
- **Author und Committer** getrennt, sobald sich Name, E-Mail oder Datum unterscheiden; sonst eine Angabe. Commit-SHA kopiert per Klick, Parent-SHA navigiert.
- **Toolbar**: Fetch-Status links, Aktionen zentriert, Suche rechts.
- **Sidebar-Raster**: fünf Spalten (Expander, Icon, Text, Wert, Status). Links nur Hierarchie; Häkchen des ausgecheckten Branches und Worktree-Glyphe stehen rechts. Aktiver Worktree und ausgecheckter Branch sind grün hinterlegt. Hover auf einem Branch mit Worktree hebt dessen Worktree-Zeile hervor.
- **WIP-Zeile**: Icons mit Zahlen, kein Text, nicht fett.
- **Drag-and-drop**: nichts wird eingeschoben; gedimmt wird pro Strang, nie pro Zeile; das Ergebnis steht als Skizze mit Kommando in einer Karte am Ziel.
- **Wording**: keine erklärenden Sätze in Panels; kein Gärtnervokabular ("Steckling") in der Oberfläche.

Offen: Titel "Working Directory" oder "Änderungen · <Worktree> (<Branch>)"; ob zusätzlich ein Ghost-Knoten im Graph gezeichnet wird.

## 1. Hauptfenster

Ein Fenster mit einem Tab pro Repository (MVP; Tabs sind essenziell, weil der Alltag mehrere Repos parallel offen hat). Die Tabs sitzen in der Titelzeile neben der Ampel, die Toolbar hängt darunter und gehört zum Repository des aktiven Tabs. Der Tab-Titel zeigt nur den Repository-Namen; Worktree und Branch stehen in der Sidebar, nicht im Tab. Ein Repository-Dropdown und ein Branch-Dropdown in der Toolbar gibt es bewusst nicht: Repository-Wechsel ist der Tab, Branch- und Worktree-Wechsel passieren in der Sidebar oder im Graph. Drei Spalten mit `NSSplitView`-Verhalten: Sidebar (min 220 pt, einklappbar), Graph (flexibel), Detail-Panel (min 360 pt, einklappbar).

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ⟵ ⟶      ⤓ Fetch   ⇣ Pull ②   ⇡ Push ①   ⑂ Branch   ⊞ Stash   ⊟ Pop            ⌕ Suche │
├─[ gitbonsai ]─┬─ example-app ──┬─ docs ─┬─ + ───────────────────────────────────────────┤
├──────────────┬──────────────────────────────────────────┬────────────────────────────┤
│ ⌄ WORKTREES 2+│ BRANCH / TAG  GRAPH  COMMIT             │ Commit  │ Working Dir │ Diff│
│ ⌂ gitbonsai  │                 ◌   ▌WIP 3 geändert, 1 st│────────────────────────────│
│   main ↑1 ↓2 │                 ┆▢   ▌stash@{0}: WIP on … │ a1b2c3f  Fix worktree …    │
│ ⑂ …-feature  │  (✓ 💻☁ main)──○   ▌Fix worktree status  │ Alex Muster · vor 2 h      │
│   feat/x ●3  │ ⑂(💻☁ feat/x)──│○  ▌Incremental layout   │ (✓ 💻☁ main)               │
│ ⌄ LOCAL     3│                 ││   ▌Neutralize config   │                            │
│  ▶ main   ↑1 │                 ○│   ▌Stream log parser   │ Parent: f4e5d6             │
│  › feature/  │     (🏷 v0.1.0)─○╯   ▌Scaffold package    │                            │
│  › hotfix/   │                 ●    ▌Merge hotfix/y      │ Geänderte Dateien (3)      │
│ ⌄ ORIGIN    3│ (☁ hotfix/y)────│─○  ▌Use optional locks  │  M Sources/Status.swift    │
│    main      │                 ○╯   ▌Add worktree parser │  A Tests/StatusTests.swift │
│  › feature/  │                 ○    ▌Initial commit      │  M docs/architecture.md    │
│  › hotfix/   │                                          │                            │
│ › UPSTREAM  1│  ○ Commit (Ring)  ● Merge  ▢ Stash  ◌ WIP │ ─ Diff der Auswahl ─       │
│ 🏷 Tags  23 ›│  (…) Pill in Strangfarbe, rechtsbündig    │ @@ -12,7 +12,9 @@          │
│ ▣ Stashes 2 ›│  ▌ Strangfarbener Balken + Zeilen-Tönung  │ + let state = …            │
│ ⌄ SUBMODULES0│  ┆ gestrichelte Linie Stash → Basis-Commit │                            │
├──────────────┴──────────────────────────────────────────┴────────────────────────────┤
│ ▸ Kommando-Log   git status --porcelain=v2 … 12 ms                                   │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 Toolbar

| Element | Aktion | Kürzel | Zustände |
|---|---|---|---|
| Zurück/Vor | Navigationshistorie der Auswahl | ⌘[ ⌘] | deaktiviert ohne Historie |
| Tab-Leiste | Ein Tab pro Repository; ⌘T öffnet ein Repository (zuletzt verwendete zuerst), ⌘W schließt den Tab, ⌘⇧[ ⌘⇧] wechselt | ⌘T ⌘W | Titel ist nur der Repository-Name |
| Fetch | `git fetch --prune --progress` | ⌘⇧F | Spinner während des Laufs |
| Pull | Dropdown: ff-only (Standard), rebase, merge; jeder Pull nimmt lokale Änderungen mit (`--autostash`) | ⌘⇧L | Badge mit Behind-Zahl (`sky`, ab 100 „99+“), ausgeblendet bei 0; Tooltip „3 Commits hinter origin/main“ |
| Push | Push aktueller Branch; Dropdown: Force-with-lease, Tags pushen | ⌘⇧U | Badge mit Ahead-Zahl (`sky`, ab 100 „99+“), ausgeblendet bei 0; Tooltip „2 Commits vor origin/main“. Ohne Upstream ein `persimmon`-Badge mit Ausrufezeichen, der Tooltip erklärt den ersten Push. Badges sitzen oben rechts auf dem Button und verschieben ihn nie |
| Branch | Neuer Branch am HEAD | ⌘B | – |
| Stash / Pop | Stash ohne Dialog: `git stash push -u -m "WIP auf <Branch>: <HEAD>"`; Dropdown: mit Nachricht, nur gestagte (`--staged`). Pop: `git stash pop` | ⌘⇧S / ⌘⇧⌥S | Toast „Gestasht: …“ mit „Rückgängig“; Stash deaktiviert ohne Änderungen, Pop ohne Stash |
| Suche | Fokus auf Filterleiste | ⌘F | – |

### 1.2 Sidebar

Abschnitte sind einklappbar; Abschnittsköpfe tragen Chevron, Quellen-Glyphe, Titel, Zähler und, wo etwas angelegt werden kann, ein rundes Plus am rechten Rand (Worktrees: neuer Worktree; Local: neuer Branch). Filterfeld oben (⌥⌘F; ⌘⇧F ist Fetch). Jeder Eintrag hat ein Kontextmenü (Abschnitt 9).

Reihenfolge und Dichte sind bewusst gewählt: In anderen Clients stehen Worktrees oft weit unten, Filter sind versteckt, der Remote-Abschnitt wird bei vielen Branches unübersichtlich. GitBonsai stellt **Worktrees an die erste Stelle**, direkt gefolgt von der Tags-Zeile; Stashes gehören als erste Zeile in den Local-Abschnitt. Die visuelle Ausarbeitung steht im [Design-System](design/README.md). GitBonsai stellt Worktrees an die erste Stelle, weil sie die erste Frage beim Öffnen beantworten ("wo arbeite ich gerade?"); Branches, Remotes, Tags und Stashes sind Navigation innerhalb dieses Kontexts.

| Abschnitt | Inhalt | Besonderheiten |
|---|---|---|
| Worktrees (immer oben, standardmäßig ausgeklappt) | Bonsai-Glyphe nach Zustand, Ordnername, Branch, Upstream, Ahead/Behind, Dirty-Punkt mit Anzahl, aktiver Worktree fett | Doppelklick wechselt das Fenster in den Worktree; "+" erstellt einen Worktree (siehe 7) |
| Tags (eine Zeile mit Zähler, direkt unter den Worktrees) | Keine Liste in der Sidebar | Klick öffnet ein durchsuchbares Popover wie GitHubs Ref-Auswahl: Fuzzy-Suche, nach Datum sortiert, annotiert mit ◆; Auswahl springt im Graph zum Commit. Tags werden nicht ausgecheckt und brauchen deshalb nicht die Priorität einer Branch-Liste |
| Local | Erste Zeile **Stashes** mit Zähler (Popover: `stash@{n}`, Nachricht, Branch, Alter; Apply, Pop, Drop, Branch aus Stash), darunter lokale Branches gruppiert nach Prefix, aktueller Branch fett mit ●, Ahead/Behind als `↑2 ↓1` | Einklappbar, Zähler im Header; Doppelklick = Checkout; Drag auf Graph-Label = Merge/Rebase (V1) |
| Ein Abschnitt pro Remote (origin, upstream, …) | Remote-Name als Titel mit Host-Glyphe (Wolke, später Host-Logo), Branches gruppiert nach Prefix; gelöschte Remote-Branches (`[gone]`) kursiv | Gleichwertig zu Local, einklappbar mit Zähler; nur der erste Remote startet ausgeklappt. Kontextmenü am Kopf: Fetch, Prune, Edit URL…, Rename…, Remove…. Neue Remotes über die Geisterzeile "Remote hinzufügen …" nach dem letzten Remote, über Repository › Add Remote… oder das Kontextmenü; Sheet mit Name und URL, Fetch nach dem Anlegen (`git remote add`, `git fetch <name>`) |
| Submodules | Name, aktueller SHA, Status (clean/modified/uninitialized) | Doppelklick öffnet das Submodul als Repo |

Zustände: leeres Repo zeigt "Noch keine Commits" mit Button "Erster Commit"; Ladezustand zeigt Skelettzeilen; Fehler (z. B. `not a git repository`) zeigt Banner mit "Repository schließen".

### 1.3 Commit-Graph

- Spalten: Graph (feste Breite nach `laneCount`, max 12 Lanes sichtbar, danach horizontaler Scroll), Subject mit Ref-Labels, Autor (Avatar + Name), Datum relativ (Tooltip absolut), SHA kurz.
- Zeile 0 pro Worktree: **WIP-Zeile** mit gestricheltem Knoten, Text "3 geändert, 1 staged, 2 untracked", nur sichtbar bei Änderungen. Klick öffnet das Working-Directory-Panel.
- Stashes erscheinen als gestrichelte Knoten (abgerundetes Quadrat) mit gestrichelter Linie zu dem Commit, auf dem sie erstellt wurden. Sie haben keinen echten Ref, deshalb bleibt die Branch/Tag-Spalte leer; rechts steht `stash@{n}: Nachricht`. Ihre Index- und Untracked-Hilfscommits werden nie gezeigt. Quelle: `git stash list`, die Stash-SHAs gehen als zusätzliche Revisionen in `git log`.
- Ref-Labels sind gestapelt: ein lokaler Branch und seine gleichnamigen Remote-Branches teilen sich ein Label mit einem Icon pro Repository (Laptop für lokal, Remote-Avatar oder Wolke pro Remote); der Pull-Request-Indikator (V2, über `gh`) sitzt im selben Label. Tags und sonstige Refs bleiben eigene Labels; Tags tragen ein eigenes Tag-Icon.
- Worktree-Indikator im Label: Ein Worktree-Icon anstelle des Laptop-Icons würde die Information "lokaler Branch" überdecken. GitBonsai zeigt beides: Laptop-Icon bleibt, daneben ein kleines Worktree-Badge mit dem Ordnernamen im Tooltip; Klick auf das Badge wechselt in den Worktree. Offener Designpunkt, mit Mockup zu prüfen.
- Ref-Labels: lokale Branches gefüllt, Remote-Branches umrandet, Tags als Raute, HEAD mit Pfeil, Worktree-HEADs mit Haus-Symbol. Labels sind Drag-Quellen und Drop-Ziele (V1).
- Auswahl: Einzelklick, ⌘-Klick für Mehrfachauswahl, ⇧-Klick für Bereich; zwei ausgewählte Commits zeigen den Diff dazwischen (V1).
- Filterleiste (⌘F) oberhalb des Graphen: Freitext (Subject/Body), Chips für Autor, Pfad, Datum, SHA; "Nur aktueller Branch" und "Remotes ausblenden" als Toggles. Treffer werden gestreamt; während der Suche ist der Graph abgedunkelt und die Treffer bleiben hell.
- Kürzel: ↑↓ Auswahl, ⏎ Checkout des Branches am Commit, Space Vorschau des Diffs, ⌘C kopiert SHA, ⌘⌥C kopiert Subject, ⌫ löscht ausgewählten Branch (mit Dialog).
- Zustände: Ladezustand zeigt gecachte Zeilen oder Skelett; Fehler im `git log` erscheint als rote Zeile am Ende des Graphen mit stderr.

### 1.4 Detail-Panel

Drei Tabs, automatisch gewählt: **Commit** bei Commit-Auswahl, **Working Directory** bei WIP-Zeile, **Diff** bei Datei-Auswahl in einem der beiden.

```
Commit-Tab                           Working-Directory-Tab                Diff-Tab
┌──────────────────────────┐         ┌──────────────────────────┐         ┌──────────────────────────┐
│ a1b2c3f  ⧉               │         │ Unstaged (3)   [Alle ⇧] │         │ Sources/Status.swift  ⤢  │
│ Fix worktree status      │         │  M Sources/Status.swift  │         │ Unified ▾  Whitespace ☐  │
│                          │         │  ? Tests/New.swift       │         │──────────────────────────│
│ Alex Muster · vor 2 h    │         │  D old.txt               │         │ @@ -12,7 +12,9 @@        │
│ Committer = Autor        │         │ Staged (1)     [Alle ⇩] │         │   let a = 1              │
│ Signiert ✓ (SSH)         │         │  A Tests/Status.swift    │         │ - let b = 2              │
│ main · origin/main       │         │──────────────────────────│         │ + let b = compute()      │
│ Parents: f4e5d6          │         │ Subject                  │         │ + let c = 3     [Stage ▸]│
│──────────────────────────│         │ ┌──────────────────────┐ │         │ @@ -40,3 +42,4 @@        │
│ Dateien (3)   Tree ▾     │         │ │Fix worktree status   │ │         │ …                        │
│  M Sources/Status.swift  │         │ └──────────────────────┘ │         │                          │
│  A Tests/Status.swift    │         │ Body                     │         │                          │
│  M docs/architecture.md  │         │ ┌──────────────────────┐ │         │                          │
│──────────────────────────│         │ │                      │ │         │                          │
│ Diff: Sources/Status.sw… │         │ └──────────────────────┘ │         │                          │
│ @@ -12,7 +12,9 @@        │         │ ☐ Amend   [Commit ⌘⏎]   │         │                          │
└──────────────────────────┘         └──────────────────────────┘         └──────────────────────────┘
```

**Commit-Tab**: SHA mit Kopieren, Subject, Body (Markdown-Links klickbar), Autor/Committer mit Datum, Signatur-Status, Refs am Commit, Eltern als Links, Dateiliste (Tree oder flach, Filter), darunter Diff der ausgewählten Datei. Kontextmenü auf Datei: "Datei zu diesem Commit öffnen", "Historie", "Blame" (V1), "In Editor öffnen".

**Working-Directory-Tab**: Unstaged-Liste (inkl. Untracked, Konflikte rot mit ⚠), Staged-Liste, je mit "Alle"-Button; Zeilen haben Hover-Buttons Stage/Unstage/Discard; Doppelklick öffnet die Datei im Editor. Darunter Commit-Formular: Subject (Zähler ab 50 Zeichen gelb, ab 72 rot), Body, Amend-Checkbox (lädt letzte Nachricht), Commit-Button (⌘⏎). Mit `.gitmessage`-Template wird das Template vorbefüllt. Zustand "sauber": Illustration Bonsai-Schale, "Working Tree ist sauber".

**Diff-Tab**: Unified (MVP) oder Side-by-side (V1), Syntax-Highlighting, Whitespace ignorieren, Kontext +/−, Wortdiff (V1). Im Working-Directory-Kontext pro Hunk Buttons "Stage hunk" / "Unstage hunk" / "Discard hunk" (mit Bestätigung), in V1 zusätzlich Zeilenauswahl mit "Stage lines". Binärdateien zeigen Größe und "Extern öffnen"; Bilder zeigen Vorher/Nachher (V2). Große Diffs (> 5 000 Zeilen) werden virtualisiert und zeigen "Datei einklappen".

Kürzel im Panel: ⌘1/⌘2/⌘3 Tab-Wechsel, S stage, U unstage, ⌘⌫ discard (Dialog), ⌘⏎ commit, ⌘⇧⏎ amend.

### 1.5 Statusbanner (Merge/Rebase/Cherry-pick/Revert)

Oberhalb des Graphen, farbig (orange bei Konflikten), mit Text "Rebase auf main: Schritt 3 von 7, 2 Konflikte" und Buttons **Fortsetzen** (aktiv, wenn keine Konflikte), **Überspringen**, **Abbrechen**. Konflikt-Dateien sind im Working-Directory-Tab rot gelistet. Das Banner bleibt, bis `.git/MERGE_HEAD` bzw. `rebase-merge/` verschwindet.

### 1.6 Kommando-Log

Einklappbares Panel am unteren Rand (⌘⌥L). Tabelle: Zeit, Kommando, Dauer, Exit-Code; Reads grau, Writes schwarz, Fehler rot. Auswahl zeigt stdout/stderr; Kontextmenü "Als Shell-Zeile kopieren". Filter: nur Writes, nur Fehler.

## 2. Öffnen und Klonen

Willkommensfenster beim Start ohne Repository: Liste der zuletzt verwendeten Repos (mit Favoriten-Stern), Buttons **Öffnen…** (⌘O, Ordner-Dialog, akzeptiert auch Unterordner eines Repos), **Klonen…** (⌥⌘N), **Init…**. Drag-and-drop eines Ordners auf das Fenster oder Dock-Icon öffnet ihn.

Klonen-Sheet: URL (HTTPS/SSH, Zwischenablage wird vorgeschlagen), Zielordner, abgeleiteter Name, Optionen "Submodule rekursiv", "Flach (depth)". Fortschritt aus `--progress` (Objekte, Delta), Abbrechen möglich. Fehler zeigen stderr vollständig, bei Auth-Fehlern Link zu Settings › Git.

## 3. Einstellungen (⌘,)

| Tab | Inhalte |
|---|---|
| General | Beim Start letztes Repo öffnen; Auto-Fetch (aus / 1 / 5 / 15 min); Datumsformat relativ/absolut; Bestätigungen (Discard, Force-Push, Branch löschen) |
| Git | Pfad zum git-Binary (erkannt: Xcode, Homebrew, eigener Pfad) mit Versionsanzeige und Mindestversion 2.38; Name/E-Mail global; Signing (aus / GPG / SSH, Key-Auswahl); Credential-Helper-Status; `commit-graph` automatisch pflegen |
| Allgemein: Editoren und Terminals | Zwei gleich gebaute Listen: gefundene Editoren (VS Code, Insiders, Cursor, Windsurf, Zed, Sublime Text, Nova, BBEdit, Xcode, JetBrains-IDEs, Android Studio, Fleet und weitere per Bundle-ID) und Terminals (Terminal, iTerm2, Ghostty, Warp, kitty, WezTerm, Alacritty, weitere per Bundle-ID und alles, was das System Shell-Programme öffnen lässt), je mit Häkchen, welche die Befehlsleiste unter „… öffnen mit …“ anbietet, Markierung „Standard“, „Andere App hinzufügen …“ und Standard-Auswahl. Diff-Tool und Merge-Tool kommen aus `git config` |
| Appearance | Theme System/Hell/Dunkel; Akzentfarbe; Schriftgröße Graph und Diff; Lane-Farbpalette; Avatare an/aus |

Repo-spezifische Werte (Name, E-Mail, Signing) stehen im Repo-Info-Sheet (Titel ▾ › Repository-Einstellungen) und schreiben `git config --local`.

## 4. Interaktives Rebase (V1)

Sheet nach „Rebase „<Branch>“ interaktiv auf … …“ im Commit-Kontextmenü (jeder Commit; an Ort und Stelle auf Vorfahren von HEAD, sonst `--onto` ab der erkannten Basis, oben änderbar) oder Drag mit ⌥ (Abschnitt 1.3). Spalten wie in der Historie: Grenzen ziehbar, Breiten gemerkt, seitlich scrollbar. Liste der Commits von alt nach neu, pro Zeile Aktion (pick, reword, squash, fixup, drop) als Popup, Drag zum Umsortieren, Subject editierbar bei reword. Vorschau rechts: resultierender linearer Verlauf als Mini-Graph. Button **Rebase starten** erzeugt die Todo-Liste und ruft `git rebase -i` mit dem Sequence-Editor-Helper. Bei Konflikten wechselt die UI ins Banner (1.5). Stacks: Checkbox "Abhängige Branches mitziehen (`--update-refs`)", vorausgewählt, wenn Branches auf Zwischen-Commits zeigen.

## 5. Konfliktlösung

**MVP**: Im Working-Directory-Tab sind Konflikt-Dateien rot mit Art (both modified, deleted by them …). Aktionen pro Datei: **Ours übernehmen**, **Theirs übernehmen**, **Im Editor öffnen** (Datei mit Markern), **Als gelöst markieren** (`git add`). Der Diff-Tab zeigt die Datei mit Markern farbig hervorgehoben (ours blau, theirs grün).

**V1 Konflikt-Editor**: Vollbild-Sheet mit drei Spalten (Ours, Theirs, Ergebnis) und Base einblendbar; pro Konflikt-Block Buttons "Ours", "Theirs", "Beide (ours zuerst)", "Beide (theirs zuerst)"; Ergebnis frei editierbar; Zähler "2 von 5 Konflikten gelöst"; **Speichern & als gelöst markieren**. Grundlage: `git show :1/:2/:3` und `git merge-file -p`.

## 6. Suche und Filter

Filterleiste über dem Graphen (⌘F). Freitext filtert Subject und Body (`--grep`, case-insensitive). Chips: `author:`, `path:`, `since:`, `until:`, `sha:`. "Inhalt (Pickaxe)" ist ein eigener Modus mit Button "Suchen", nicht live. Ergebnisse: Graph bleibt vollständig, Nicht-Treffer abgedunkelt; ↑↓ springt zwischen Treffern; Esc löscht. Zustände: "Keine Treffer", Spinner mit Abbrechen bei langen Walks.

## 7. Worktrees (Sidebar-Abschnitt und Sheet)

Sidebar-Eintrag pro Worktree: Ordnername (Tooltip voller Pfad), Branch oder "detached @ sha", `↑n ↓m`, Dirty-Punkt mit Anzahl geänderter Dateien, Schloss bei locked, grau bei prunable. Hauptworktree steht oben mit Haus-Symbol; der im Fenster aktive Worktree ist fett.

Aktionen: Doppelklick wechselt das Fenster auf den Worktree (Graph bleibt, WIP-Zeile und Status wechseln). Kontextmenü: Im Finder zeigen, Im Terminal öffnen, Im Editor öffnen, Sperren/Entsperren, Entfernen (Dialog, `--force` nur bei dirty nach zweiter Bestätigung), Prune.

Sheet "Worktree anlegen" (+ im Abschnitt, Kontextmenü eines Branches, ⌘⇧W): Branch (bestehend oder neu ab Start-Ref), Pfad (Standard `../<repo>-<branch>`), Checkbox "Nach dem Anlegen wechseln". Im Graph trägt jeder Worktree-HEAD ein Haus-Label und bei Änderungen eine eigene WIP-Zeile (V1).

## 8. Drag-and-drop (V1)

Quellen: Branch-Labels im Graph, Branch-Einträge der Sidebar, Commit-Zeilen. Ziele: Branch-Labels, Commit-Zeilen, Remote-Branch-Labels. Während des Drags ist das Layout eingefroren, der Ghost ist ein Overlay (siehe [Flows › Merge per Drag](flows.md#5-merge-per-drag-and-drop-mit-ghost-preview)). Der Tooltip am Cursor zeigt das Kommando, das beim Loslassen läuft; ⌥ wechselt Merge zu Rebase. Ungültige Ziele zeigen das Verbotssymbol.

## 9. Kontextmenüs

| Element | Einträge |
|---|---|
| Commit | Checkout (detached), Branch hier erstellen, Tag hier erstellen, Cherry-pick auf aktuellen Branch, Revert, Reset aktuellen Branch hierher (soft/mixed/hard), Rebase auf diesen Commit (erkannte Basis), Rebase interaktiv auf diesen Commit (V1), Diff zu Auswahl (V1), SHA kopieren, Subject kopieren, Auf GitHub öffnen (V2) |
| Lokaler Branch | Checkout, In aktuellen Branch mergen, Aktuellen Branch hierauf rebasen, Umbenennen, Upstream setzen, Push, Pull, Worktree anlegen, Löschen, Löschen inkl. Remote |
| Remote-Branch | Checkout als lokalen Branch, In aktuellen Branch mergen, Rebase hierauf, Pull-Request öffnen (V2), Remote-Branch löschen |
| Tag | Checkout, Pushen, Löschen, Löschen inkl. Remote, Nachricht anzeigen |
| Stash | Pop, Apply, Drop, Branch aus Stash |
| Worktree | siehe Abschnitt 7 |
| Datei (Working Dir) | Stage, Unstage, Discard, Ignorieren (`.gitignore`), Im Editor öffnen, Im Finder zeigen, Historie, Blame (V1), Pfad kopieren |
| Datei (Commit) | Datei zu diesem Commit öffnen, Historie, Blame (V1), Diff extern öffnen, Pfad kopieren |
| Hunk | Stage/Unstage, Discard, Zeilen auswählen (V1) |

## 10. Globale Kürzel

| Kürzel | Aktion |
|---|---|
| ⌘⇧P | Befehlsleiste (Abschnitt 11) |
| ⌘O / ⌥⌘N | Öffnen / Klonen |
| ⌘T / ⌘W | Neuer Tab / Tab schließen; in Einstellungen und anderen Fenstern schließt ⌘W das Fenster |
| ⌘E | Nachricht des ausgewählten Commits im Detailpanel bearbeiten (Sichern ⌘⏎, Abbrechen Esc) |
| ⌘⇧] / ⌘⇧[ | Nächster / vorheriger Tab |
| ⌘1 ⌘2 ⌘3 | Detail-Tabs |
| ⌃⌘S / ⌥⌘I | Seitenleiste / Detail-Panel ein- und ausblenden (⌥⌘D gehört dem Dock); ⌘⌥L Kommando-Log |
| ⌘⇧F / ⌘⇧L / ⌘⇧U | Fetch / Pull / Push |
| ⌘B | Neuer Branch |
| ⌘⇧S / ⌥⇧⌘S | Stash / Stash poppen |
| ⌘F | Commits durchsuchen |
| ⌘⇧T | Im Terminal öffnen; ⌘⇧E im Editor; ⌘⇧R im Finder |
| ⌘R | Manuell aktualisieren |

Die Menüleiste (GitBonsai, Ablage, Bearbeiten, Darstellung, Repository, Branch, Fenster, Hilfe) entsteht aus denselben Befehlen wie die Befehlsleiste (`CommandSpec`, `MainMenu`): gleiche Titel, Kürzel und Aktivierung; im leeren Tab bleiben die Git-Einträge sichtbar und deaktiviert. Einträge mit „…“ und Argument öffnen die zweite Liste der Befehlsleiste. Nur was AppKit selbst kann (Textbearbeitung, Ausblenden, Dienste, Dock, Vollbild) bleibt ein Systemeintrag. Push lag früher auf ⌘⇧P und ist für die Befehlsleiste auf ⌘⇧U gewandert.

## 11. Befehlsleiste (⌘⇧P)

Schwebendes Panel aus Liquid Glass, zentriert unter der Toolbar: Suchfeld, darunter bis zu zehn Zeilen. Jede Zeile zeigt Glyphe, Titel mit hervorgehobenen Treffern, gedämpften Kontext („main“, „origin“, Repository-Name, Editor) und rechts das Kürzel, falls es eines gibt.

- Tippen filtert unscharf über Titel und Stichwörter; jedes Wort der Eingabe muss passen, Wortanfänge zählen mehr. Zuletzt benutzte Befehle stehen oben.
- ↑ ↓ wählen, ⏎ führt aus, Esc oder ein Klick daneben schließt.
- Befehle mit Argument öffnen eine zweite Liste im selben Panel („Branch auschecken …“, „Zu Tab wechseln …“, „Im Editor öffnen mit …“, „Im Terminal öffnen mit …“, „Worktree wechseln …“, „Rebase interaktiv …“); ⌫ im leeren Feld geht zurück.
- Was gerade nicht geht, bleibt grau in der Liste, unter den möglichen Befehlen, mit dem Grund statt des Kontexts („Kein Upstream“, „Nichts vorgemerkt“, „Kein Stash“). So findet man den Befehl und erfährt, warum er nicht läuft, statt ihn zu vermissen. Befehle, deren Gegenstand fehlt, erscheinen gar nicht: „Rebase fortsetzen/abbrechen“ nur während eines Rebase.
- Ein leerer Tab bietet nur die Befehle des Fensters (Tabs, Öffnen, Klonen, Einstellungen).
