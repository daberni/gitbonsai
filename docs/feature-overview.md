# GitBonsai — nativer macOS Git-Client: Feature-Überblick und Aufwandsanalyse

Siehe auch: [Architektur](architecture.md) · [Screens](screens.md) · [Flows](flows.md) · [Designs](design/README.md)

Stand: 2026-11-22, Revision 3 (Scope nach Review angepasst, Name festgelegt).

## 1. Zielbild und Prinzipien

- Graph-zentrierte UX: zentraler Commit-Graph mit Working-Directory-Zeile ("WIP") im Graph, rechtes Detail-Panel (Commit / Working Directory / Diff), linkes Panel (Local, Remote, Tags, Stashes, Worktrees, Submodules), Drag-and-drop-Aktionen im Graph.
- **Prinzip 1: Alles über die git-CLI.** Es wird nichts nachgebaut, was git nicht selbst kann. Die App ist eine Visualisierung und ein Steuerpult für `git`; jede Aktion entspricht einem sichtbaren git-Kommando (Kommando-Log). Einzige Nicht-git-Bausteine: Graph-Layout, Syntax-Highlighting, Dateisystem-Watching, Aufruf von `gh`/`glab` für PR-Links (erst V2).
- **Prinzip 2: Kein KI-Feature, kein integriertes Terminal, keine Cloud.** Nur "Open in Terminal/Editor/Finder".
- **Prinzip 3: Worktrees als First-Class-Konzept.** Jeder Worktree mit Branch, Tracking-Status und `git status` sichtbar, nicht als Untermenü.
- Qualitätsziel: 100k+ Commits und 10k+ geänderte Dateien ohne spürbare Latenz; niedriger Speicherverbrauch.

## 2. Architektur mit git-CLI-Backend

### 2.1 Kernschicht (`GitEngine`)

| Baustein | Umsetzung | Anmerkung |
|---|---|---|
| Prozess-Runner | `Process` + Pipes, async/await, stdout wird gestreamt | Pro Repo ein Runner; Lese-Kommandos parallel, Schreib-Kommandos seriell |
| Umgebung | `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0` für Reads, `GIT_ASKPASS` auf eigenen Helper, `-c core.quotepath=off -c color.ui=never` | Verhindert Hänger auf Credential-Prompts; neutralisiert Nutzerkonfiguration |
| Log/Graph-Daten | `git log --all --topo-order --format=<NUL-getrennte Felder> -z --parents`, gestreamt und in Seiten verarbeitet | Layout wird inkrementell aus dem Stream aufgebaut (Topo-Order garantiert: Kinder vor Eltern) |
| Status | `git status --porcelain=v2 -z --untracked-files=all --branch` | Eine Quelle für Staged/Unstaged/Untracked/Konflikte |
| Diff | `git diff` / `diff-index` / `diff-tree` mit `--no-color -p -z`; Hunk stagen = Hunk unverändert + Dateiheader an `git apply --cached` | Hunk-Staging ist trivial; Zeilen-Staging (V1) erfordert Patch-Umbau |
| Refs | `git for-each-ref --format=…` | Branches, Tags, Remotes, Upstream, Ahead/Behind |
| Worktrees | `git worktree list --porcelain` + `git -C <pfad> status --porcelain=v2 --branch` pro Worktree | Tracking-Branch, Ahead/Behind, dirty/clean |
| Suche | `git log --grep/--author/--since/-S/-G/-- <pfad>`, `git grep` | Alles nativ, keine eigene Indizierung |
| Interaktives Rebase | `GIT_SEQUENCE_EDITOR` auf eigenen Helper; Todo-Liste schreibt die App; `rebase --update-refs` für Stacks | Kein TTY nötig |
| Konflikte | `git diff --diff-filter=U`, `git show :1:/:2:/:3:<pfad>`, `git checkout --ours/--theirs`, `git merge-file`, Ergebnis schreiben + `git add` | Alles nativ |
| Credentials | Git-Credential-Helper (`osxkeychain`), SSH-Agent | Kein eigenes Credential-Handling |
| Hosting | `gh pr list/view --json`, `glab mr list` (falls installiert) | Nur Abfrage und Verlinkung, keine eigene OAuth-Integration |
| Watching | FSEvents auf Working Tree + `.git` (HEAD, refs, index, MERGE_HEAD, …), Debounce, Refresh-Scheduler | Grundlage für "fühlt sich live an" |

### 2.2 Lazy Graph: so funktioniert es

1. `git log` wird gestartet und nicht abgewartet; die ersten ~300 Commits erscheinen nach wenigen Millisekunden.
2. Das Lane-Layout wird zeilenweise inkrementell berechnet (Topo-Order garantiert, dass Eltern erst nach allen Kindern kommen). Jede Zeile kennt nur: aktive Lanes, eigene Lane, Verbindungen zu Eltern.
3. Die Liste ist virtualisiert (NSTableView/NSCollectionView via `NSViewRepresentable`); gezeichnet wird nur der sichtbare Ausschnitt mit CoreGraphics. SwiftUI-Views pro Commit scheiden aus.
4. Weitere Seiten werden beim Scrollen nachgeladen; Commit-Metadaten werden pro Repo gecacht (SQLite), damit der Neustart sofort anzeigt.
5. Refs, Avatare und Status werden separat geladen und nachträglich in die Zeilen gemischt.

### 2.3 Drag-and-drop im Graph (Konzept)

Ziel: Der Nutzer sieht vor dem Loslassen, was passieren würde ("Ghost-Preview"), und der Drop führt genau ein git-Kommando aus.

| Geste | Vorschau während des Drags | Drop-Ergebnis |
|---|---|---|
| Branch-Label auf anderes Branch-Label ziehen | Ghost-Merge-Commit oberhalb der Ziel-Branch-Spitze; die beiden beteiligten Lanes werden hervorgehoben, alle anderen abgedunkelt | `git merge <quelle>` (⌥ gedrückt: `git rebase <ziel>`) |
| Branch-Label auf Branch ziehen, ⌥ gedrückt | Ghost-Kopien der abweichenden Commits linear oberhalb des Ziels; ursprüngliche Lane halbtransparent | `git rebase <ziel>` |
| Einzelnen Commit (oder Auswahl) auf Branch-Label ziehen | Ghost-Commit oberhalb des Ziel-Branches | `git cherry-pick <sha…>` |
| Branch-Label auf einen Commit ziehen | Branch-Label springt als Ghost an den Commit | `git branch -f` (bei aktuellem Branch: `git reset`) nach Bestätigung |
| Branch-Label auf Remote-Branch ziehen | Ghost-Remote-Label an der Spitze | `git push` (Force nur mit Bestätigung und `--force-with-lease`) |

Einschränkungen: Drop-Ziele sind nur Branch-Spitzen (Forks) und einzelne Commits; Merge-Commits sind als Drag-Quelle für Cherry-pick gesperrt (bzw. nur mit `-m` nach Nachfrage). Die Ghost-Vorschau ist rein visuell und wird aus den bekannten Graph-Daten berechnet, nie aus einem Probelauf von git. Drop zeigt immer das exakte Kommando und ein Abbrechen-Fenster, solange ein Rebase/Merge läuft.

## 3. Feature-Inventar

Legende Aufwand (klassisch, eine erfahrene Person inkl. UI und Tests): **S** < 1 Woche, **M** 1–3 Wochen, **L** 1–2 Monate, **XL** > 2 Monate.
Legende Phase: **MVP** = täglich nutzbar, **V1** = vollständiger Alltagsclient, **V2** = später, **✗** = bewusst nicht.

### 3.1 Repository und Worktrees

| Feature | git-CLI | Aufwand | Phase |
|---|---|---|---|
| Repo öffnen, zuletzt verwendete Repos, ein Tab pro Repository | – | M | MVP |
| Clone (HTTPS/SSH, Fortschritt via `--progress`), Init | ✅ | S | MVP |
| **Worktrees: Liste mit Branch, Upstream, Ahead/Behind, dirty/clean** | ✅ | M | MVP |
| Worktree anlegen (aus Branch/neuem Branch), wechseln, entfernen, prune | ✅ | S | MVP |
| Worktree im Graph: eigenes HEAD-Label, eigene WIP-Zeile | ✅ | M | V1 |
| Submodule anzeigen, init/update, öffnen | ✅ | M | V1 |
| Repo-Profile (Name/E-Mail/Signing pro Repo) | ✅ | S | V1 |
| Git LFS Status, Lock/Unlock | ✅ | M | V2 |
| Open in Terminal / Editor / Finder (konfigurierbar) | – | S | MVP |

### 3.2 Commit-Graph

| Feature | git-CLI | Aufwand | Phase |
|---|---|---|---|
| Lazy Graph-Layout (Lanes, Merges, Farben), gestreamt | Daten ✅ | L | MVP |
| Virtualisiertes Rendering, 100k+ Commits | – | L | MVP |
| WIP-Zeile (lokale Änderungen) im Graph | ✅ | M | MVP |
| Ref-Badges (Branches, Tags, HEAD, Remote-Tracking, Worktree-HEADs) | ✅ | M | MVP |
| **Suche/Filter: Nachricht, Autor, SHA, Pfad, Datum, Pickaxe (`-S/-G`)** | ✅ | M | MVP |
| Filter "nur aktueller Branch" / Remotes ausblenden | ✅ | S | MVP |
| Kontextmenü mit allen Aktionen pro Commit/Ref | ✅ | M | MVP |
| Commit-Auswahl, Multi-Select, Diff zwischen zwei Commits | ✅ | M | V1 |
| Drag-and-drop mit Ghost-Preview (Abschnitt 2.3) | ✅ | L | V1 |
| Avatare (Gravatar) | – | S | V1 |
| Solo-Branch-Ansicht, Merge-Pfade einklappen | – | M | V2 |

### 3.3 Working Directory und Staging

| Feature | git-CLI | Aufwand | Phase |
|---|---|---|---|
| Unstaged/Staged-Listen, Tree- und Flat-View | ✅ | M | MVP |
| Datei stagen/unstagen/discard, Alle stagen | ✅ | S | MVP |
| **Hunk-basiertes Stagen/Unstagen/Discard** | ✅ | M | MVP |
| Zeilenweises Stagen | ✅ (Patch-Umbau) | M | V1 |
| Commit (Subject/Body), Amend, Commit-Template | ✅ | S | MVP |
| Commit-Signing (GPG/SSH) inkl. Status-Anzeige | ✅ | M | V1 |
| Untracked/Ignored, `.gitignore` bearbeiten | ✅ | S | MVP |
| Konflikt-Dateien erkennen und markieren | ✅ | S | MVP |
| Live-Refresh (FSEvents), Burst-Koalition | – | M | MVP |
| Große Working Trees ohne UI-Blockade | – | M | V1 |

### 3.4 Diff und Blame

| Feature | git-CLI | Aufwand | Phase |
|---|---|---|---|
| Unified Diff mit Syntax-Highlighting, virtualisiert | ✅ | L | MVP |
| Side-by-side Diff | ✅ | M | V1 |
| Whitespace ignorieren, Kontext erweitern, Wortdiff | ✅ | S | V1 |
| Datei-Historie (`log --follow`) | ✅ | M | V1 |
| Blame (`blame --porcelain`) mit Commit-Hover | ✅ | M | V1 |
| Datei zu Commit öffnen / in Editor öffnen | ✅ | S | MVP |
| Externes Diff-/Merge-Tool (`difftool`/`mergetool`) | ✅ | S | V1 |
| Bild-Diff | – | M | V2 |

### 3.5 Branches, Tags, Remotes

| Feature | git-CLI | Aufwand | Phase |
|---|---|---|---|
| Branch erstellen/umbenennen/löschen/checkout | ✅ | S | MVP |
| Upstream setzen, Ahead/Behind | ✅ | S | MVP |
| Fetch / Pull (merge, rebase, ff-only) / Push (`--force-with-lease`) | ✅ | M | MVP |
| Auto-Fetch im Intervall | ✅ | S | V1 |
| Remotes verwalten | ✅ | S | MVP |
| Tags (leicht/annotiert/signiert), Push Tags; Sidebar-Eintrag mit durchsuchbarem Popover statt Liste | ✅ | S | MVP |
| Branch-Liste mit Filter, Gruppierung nach Prefix | ✅ | S | MVP |
| Prune, gelöschte Remote-Branches anzeigen | ✅ | S | V1 |

### 3.6 Merge, Rebase, Konflikte, Stacks

| Feature | git-CLI | Aufwand | Phase |
|---|---|---|---|
| Merge (ff, no-ff, squash), Abbruch | ✅ | S | MVP |
| Rebase onto, Abbruch, Continue, Skip | ✅ | M | MVP |
| Cherry-pick, Revert | ✅ | S | MVP |
| Reset (soft/mixed/hard) | ✅ | S | MVP |
| Merge-/Rebase-Status-Banner mit Aktionen | ✅ | S | MVP |
| Interaktives Rebase als UI (pick/squash/reword/drop/reorder) | ✅ | L | V1 |
| **Stacked Branches: Rebase mit `--update-refs`, Stack-Ansicht aus Branch-Vorfahren** | ✅ (git ≥ 2.38) | M | V1 |
| Konflikt-Editor (ours/theirs/result, hunkweise übernehmen) | ✅ | XL | V1 |
| Konflikt minimal: Datei mit Markern im Editor öffnen, ours/theirs ganze Datei, "als gelöst markieren" | ✅ | S | MVP |

### 3.7 Stash und Reflog

| Feature | git-CLI | Aufwand | Phase |
|---|---|---|---|
| Stash (inkl. untracked, Nachricht), Pop/Apply/Drop, Stash-Diff | ✅ | M | MVP |
| Stashes als gestrichelte Knoten im Graph auf ihrem Basis-Commit, ohne Label links, Hilfscommits verborgen | ✅ (`stash list` + Log-Revisionen) | S | MVP |
| Partieller Stash (ausgewählte Dateien) | ✅ | S | V1 |
| Reflog-Browser mit "HEAD hierhin zurücksetzen" | ✅ | S | V2 |
| Undo/Redo-Stack | ✗ nicht git-nativ | – | ✗ |

### 3.8 Hosting (nur Abfrage und Verlinkung, V2)

| Feature | git-CLI | Aufwand | Phase |
|---|---|---|---|
| PR-Badge am Branch (Nummer, Status, Checks) via `gh`/`glab` | ✅ (CLI) | S | V2 |
| PR im Browser öffnen, PR-Branch auschecken (`gh pr checkout`) | ✅ (CLI) | S | V2 |
| PR erstellen über `gh pr create --web` mit vorbelegter Base (Stacks) | ✅ (CLI) | S | V2 |
| Inline-PR-Ansicht, Reviews, Issues | ✗ | – | ✗ |
| Eigene OAuth-Integration | ✗ | – | ✗ |

### 3.9 App-Grundfunktionen

| Feature | Aufwand | Phase |
|---|---|---|
| Einstellungen (Git-Pfad, Editor, Terminal-App, Diff-Tool, Auto-Fetch, Signing) | M | MVP |
| Kommando-Log (jedes git-Kommando mit Ausgabe sichtbar) | S | MVP |
| Themes (Light/Dark/System), Schriftgrößen | S | MVP |
| Fehlerdialoge mit vollständiger git-Ausgabe | S | MVP |
| Tastaturkürzel, Command Palette | M | V1 |
| Notarization, Sandbox-Entscheidung, Auto-Update (Sparkle) | M | MVP |
| Lizenzierung / Vertrieb (falls kommerziell) | M | V1 |
| Lokalisierung (DE/EN) | S | V2 |
| Integriertes Terminal, KI-Features, Issues, Cloud/Teams | – | ✗ |

## 4. Stack-Vergleich

| Kriterium | SwiftUI + AppKit | React Native macOS | Electron / Tauri |
|---|---|---|---|
| Performance Graph/Diff | Sehr gut (CoreGraphics, TextKit 2, virtualisierte NSViews) | Mäßig; Graph müsste trotzdem nativ gezeichnet werden | Wie Electron-Clients, kein Gewinn |
| Native Look-and-feel | Nativ | Teilweise | Nachgebaut |
| Ökosystem-Reife macOS | Sehr gut | Schwach (kleine Community, viele Libraries ohne macOS) | Sehr gut (Web) |
| Prozess-/Datei-Zugriff | Direkt | Native Module nötig, doppelter Code | Node/Rust-Backend |
| KI-Eignung | Gut: Swift-Backend und Parser sind testgetrieben, UI braucht Screenshot-Loop | Gut bei JS, schlecht bei den nativen Modulen | Sehr gut |
| Fazit | **Empfehlung** | Nicht empfohlen | Nur bei Cross-Platform-Priorität |

Verteilung bei SwiftUI: App-Chrome, Sidebar, Listen, Settings in SwiftUI; Commit-Graph, Diff-Viewer und Konflikt-Editor als AppKit-Views (`NSViewRepresentable`).

## 5. Aufwandsschätzung

### 5.1 Klassisch (eine erfahrene Person, Vollzeit, ohne KI)

| Phase | Inhalt | Aufwand (Personenmonate) |
|---|---|---|
| 0. Fundament | GitEngine, Parser, Prozess-Queue, FSEvents, Fixture-Tests | 1–1,5 |
| 1. MVP | Lazy Graph + WIP-Zeile, Hunk-Staging, Diff-Viewer, Suche, Worktrees, Branches/Remotes, Merge/Rebase/Stash, Minimal-Konflikte, Settings, Notarization | 4–6 |
| 2. V1 | Drag-and-drop mit Ghost-Preview, interaktives Rebase, `--update-refs`-Stacks, Konflikt-Editor, Zeilen-Staging, Blame/Historie, Side-by-side, Command Palette | 6–9 |
| 3. V2 | PR-Badges und Checkout via `gh`, LFS, Reflog, Bild-Diff, Lokalisierung | 1–3 |
| laufend | Performance-Härtung, Edge-Cases | +15–25 % |

Summe bis V1: ca. **11–17 PM** (Revision 1: 13–20 PM; Reduktion durch Wegfall von Undo/Redo, Issues, Terminal, KI, OAuth-Integrationen, Zeilen-Staging im MVP).

### 5.2 KI-getrieben

Was davon auf dieses Projekt übertragbar ist, nach Teilbereich:

| Bereich | Anteil an V1 | KI-Faktor | Begründung |
|---|---|---|---|
| GitEngine, Parser, Prozess-Queue, Fixture-Tests | ~20 % | 6–10× | Reine Logik, exakt testbar gegen echte Repos; Agenten können hier autonom iterieren |
| Graph-Layout-Algorithmus | ~10 % | 4–6× | Testbar (Snapshot-Tests gegen bekannte Repos), aber Korrektheit bei Octopus-Merges braucht Review |
| Graph-/Diff-Rendering (AppKit, Performance) | ~20 % | 2–3× | Profiling und Scroll-Gefühl brauchen Menschen und echte Hardware; Xcode-Build-Loop ist langsamer als Next.js-HMR |
| SwiftUI-Chrome, Listen, Settings, Dialoge | ~20 % | 3–5× | Agenten liefern schnell; visuelle Abnahme über Screenshot-Loop (`screencapture`, Accessibility) |
| Drag-and-drop, interaktives Rebase, Konflikt-Editor | ~20 % | 2–3× | Interaktionsdesign, viele Zustände, Abnahme nur manuell |
| Notarization, Sparkle, Packaging | ~5 % | 3–5× | Gut dokumentiert, einmalig |
| Polish, Edge-Cases, Performance-Härtung | ~5 %+ | 1,5–2× | Hier kippt der Faktor: Fehler in echten Repos findet der Mensch |

Gewichteter Faktor über V1: etwa **3–4×** gegenüber klassisch. Daraus:

| Meilenstein | Klassisch | KI-getrieben, Kalenderzeit bei intensiver Betreuung | KI-getrieben, bei ~2 Tagen/Woche |
|---|---|---|---|
| Spike (Engine + lazy Graph gegen 100k-Repo) | 2–3 Wochen | 2–4 Tage | 1 Woche |
| MVP täglich nutzbar | 5–7,5 PM | 3–5 Wochen | 2–3 Monate |
| V1 | 11–17 PM | 8–14 Wochen | 5–8 Monate |

Annahmen und Unsicherheit:
- Swift/AppKit ist für Agenten weniger "verdichtet" als Next.js: kein Hot Reload, längere Builds, visuelle Verifikation über Screenshots statt Browser-Tools, kleinere Trainingsbasis für AppKit-Virtualisierung und TextKit 2.
- Die größte Unsicherheit ist nicht die Menge der Features, sondern das Scroll- und Interaktionsgefühl des Graphen. Das ist mit Agenten nicht beschleunigbar, nur die Iterationen darum.
- Nicht enthalten: Vertrieb, Lizenzierung, Support, Website.

### 5.3 Empfohlener Arbeitsmodus

1. Repo mit `AGENTS.md`, Architektur-Doc, Fixture-Repos (`linux`-Subset, `homebrew-core`, ein Monorepo, ein Repo mit Octopus-Merges und Worktrees) und Snapshot-Tests für Parser und Layout.
2. GitEngine als eigenes Swift-Package mit 100 % CLI-Abdeckung durch Tests; Agenten arbeiten hier weitgehend autonom.
3. UI in einer zweiten Schicht; jede UI-Aufgabe bekommt ein Screenshot-Akzeptanzkriterium.
4. Performance-Budget als Test: Zeit bis erste 300 Commits sichtbar < 100 ms, Scroll 60 fps bei 100k Commits, Status-Refresh < 200 ms bei 10k Dateien.

## 6. Hauptrisiken

1. **Graph-Rendering**: Korrektheit und Flüssigkeit. Früh prototypen, Performance-Budget als Test.
2. **git-Ausgabe als API**: Versionsunterschiede (Apple-Git vs. Homebrew-Git), Nutzerkonfiguration neutralisieren (`-c …`, `GIT_CONFIG_*`); Minimum-Version festlegen (≥ 2.38 wegen `--update-refs`).
3. **Credential-Prompts**: jeder Hänger friert eine Operation ein; `GIT_TERMINAL_PROMPT=0` und eigener `GIT_ASKPASS` von Anfang an.
4. **SwiftUI-Grenzen**: große Tabellen, Text-Rendering, Drag-and-drop zwischen Panels. AppKit-Fallback einplanen.
5. **Konflikt-Editor**: größter Einzelposten in V1; MVP kommt bewusst mit Minimal-Variante aus.

## 7. Wettbewerb (Kurzcheck)

| Produkt | Backend | Relevanz |
|---|---|---|
| Fork | git-CLI, Cocoa | Funktional am nächsten; UI und Graph-Visualisierung sind die Lücke |
| Tower | git-CLI, nativ | Stark bei Workflows und Undo; Abo-Modell |
| GitUp | libgit2 | Beste Graph-Performance, Entwicklung ruht |
| Sourcetree | git-CLI | Veraltet, langsam |

## 8. Einstieg

1. Spike (2–4 Tage KI-getrieben): GitEngine mit log/status/diff-Parsern, lazy Graph-Layout, virtualisiertes Rendering gegen ein 100k-Commit-Repo. Ergebnis entscheidet SwiftUI/AppKit-Verteilung und bestätigt den Performance-Anspruch.
2. MVP-Reihenfolge: WIP-Zeile + Hunk-Staging + Diff → Worktrees + Suche → Branches/Remotes → Merge/Rebase/Stash → Settings/Notarization.
3. V1 beginnt mit Drag-and-drop-Ghost-Preview, weil das die sichtbare Differenzierung ist.

## 9. Name und Branding

Produktname **GitBonsai**, Repo-Schreibweise `git-bonsai` oder `gitbonsai`. Entscheidung vom 2026-11-22.

- Metapher: einen Baum über Jahre in Form bringen. Beschneiden = Squash/Drop/interaktives Rebase, Verdrahten = Rebase onto, Pfropfen = Cherry-pick, Totholz entfernen = Prune, Schale = Repo, Stamm = main, Nebari (Wurzelansatz) = Historie/Reflog.
- Tonalität: ruhig, geduldig, handwerklich; keine KI-Buttons, kein Kraken-Lärm.
- Icon-Richtung: kleiner Baum in flacher Schale, Äste als Commit-Graph mit Knoten.
- Bekannte Nachbarn mit gleichem Namen, alle nischig und keine Clients: StevenBtw/gitbonsai (Profil-SVG, besitzt gitbonsai.dev), egorthinks/git-bonsai (Pixel-Art-Profil), agateau/git-bonsai (Branch-Aufräum-CLI).
- Kennungen: GitHub-Handle `gitbonsai` frei; `gitbonsai.com` frei; `gitbonsai.app` und `gitbonsai.io` ohne DNS, beim Registrar zu prüfen; `gitbonsai.dev` belegt.
- Verworfene Alternativen (Kurzliste): TreeWright, Stemma, Zweig/Zweigit, GitBraid, GitPlexus, Arboriste/Arbisto, GitNiwaki, Gitbonzai.
