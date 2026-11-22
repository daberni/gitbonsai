GitBonsai ist ein nativer macOS-Git-Client. Seine Gestaltung folgt dem Bonsai: ruhig, warm, handwerklich, geduldig. Nichts blinkt, nichts drängt. Der Graph ist die Pflanze, die Oberfläche die Schale.

## Prinzipien

1. **Warm statt neutral.** Jede Fläche und jedes Grau trägt einen Hauch Rinde oder Papier. Reines Weiß nur für Popover und Eingabefelder (`surface-2`), reines Schwarz nirgends.
2. **Weich, aber präzise.** Runde Enden, runde Ringe, Pills; dafür exakte 1-px-Hairlines und klare Spalten. Weich ist die Form, nicht die Information.
3. **Der Graph ist die Hauptfigur.** Farbe gehört zuerst den Strängen. Chrome, Sidebar und Text bleiben in Papier und Tinte, damit der Graph leuchtet.
4. **Eine Metapher, sparsam.** Bonsai-Bilder und -Wörter erscheinen in Marke, Onboarding, Leerzuständen und Worktree-Icons. Die Arbeitsoberfläche spricht Git: Branch, Rebase, Stash, Worktree.
5. **Kein Lärm.** Keine KI-Buttons, keine Werbeflächen, keine Badges ohne Bedeutung. Jede Hervorhebung sagt etwas über den Zustand des Repos.

## Stimme und Text

- Deutsch in der Doku und im Marketing, Englisch in der Oberfläche (Git-Begriffe bleiben englisch, auch in deutscher Lokalisierung: "Rebase auf main", nicht "Umbasieren").
- Ruhige, vollständige Sätze. Keine Ausrufezeichen, keine Emojis in der Oberfläche. Buttons benennen die Handlung mit dem Git-Verb: "Merge feature/graph", "Push with lease", "Drop stash".
- Beschriftungen von Aktionen (Buttons, Menüeinträge, Banner-Aktionen) sind immer einzeilig; bei Platzmangel wird der erklärende Text gekürzt, nie die Aktion umgebrochen.
- Fehler zeigen die vollständige git-Ausgabe im Monospace (`code`) unter einem kurzen Satz, der sagt, was zu tun ist.
- Die Metapher darf in Leerzuständen und Onboarding sprechen, aber nur mit dem Wort Bonsai und den Git-Begriffen; Gärtnervokabular wie "Steckling" kommt in der Oberfläche nicht vor. In Dialogen keine Metapher.

## Farbe

- Flächen: `surface-0` für Fenster und Graph, `surface-1` für Sidebar, Toolbar, Tabs und Statusleiste, `surface-2` für alles, was darüber schwebt. Trennlinien immer `hairline`.
- Text: `ink` auf allen Flächen; `ink-muted` für Autor, Datum, Zähler; `ink-faint` nur für gedimmte Commits außerhalb des aktuellen Branches und nur ab 13 px.
- Akzent: `moss` ist die einzige Primärfarbe. Primärbutton, Links, aktiver Tab, Fokusring, ausgecheckter Branch. Text auf `moss` in `on-moss`.
- `clay` markiert Worktrees und handwerkliche Eingriffe (Rebase-Banner, Worktree-Badges). Nie als zweiter Primärakzent für Buttons.
- Zustände: `ochre` warnt, `persimmon` gefährdet, `sky` informiert; jede mit ihrer `-soft`-Fläche als Hintergrund. Ein Zustand trägt immer auch ein Wort oder Icon, nie nur Farbe.
- Graph-Stränge: die zwölf `strand-*`-Farben zyklisch in der angegebenen Reihenfolge, damit Nachbarstränge nie derselben Hue-Familie angehören. Im Dark Mode sind sie bewusst gedämpft; die Linie trägt die Farbe, nicht die Fläche.
- Dark Mode ist kein invertiertes Light: Stränge werden heller und etwas entsättigt, Akzente werden zu hellen Flächen mit dunklem Text (`on-moss`).

## Typografie

- Oberfläche in der Systemschrift (`ui`, SF Pro): `body` 13/18 für alles Lesbare, `body-strong` für HEAD, aktiven Worktree und ausgecheckten Branch, `caption` für Autor, Datum, Zähler, `label` versal für Abschnittstitel und Spaltenköpfe.
- Marke in `display` (Fraunces, weich, mit optischer Größe): `wordmark` und `display` nur in Onboarding, About, Website, Leerzuständen. Nie in Listen, Dialogen oder der Toolbar.
- Code in `mono`: Diffs, Kommando-Log, Pfade, SHAs (`sha` in Listen). Tabellarische Ziffern überall, wo Zahlen untereinander stehen. Zeitangaben relativ ("gestern", "vor 1 Woche"), der exakte Zeitstempel beim Hover als Tooltip.

## Form und Raum

- Radien: `radius-sm` für Buttons und Felder, `radius-md` für Tabs (oben, mit Gegenrundung in den Inhalt wie in Chrome), Popover und Banner, `radius-lg` für Sheets, `radius-pill` für jedes Label. Der Stash-Knoten ist das einzige Quadrat (`radius-xs`).
- Abstände aus der 4-px-Skala; Zeilen in Graph und Sidebar sind `row` (26 px) hoch, Lanes liegen `lane` (18 px) auseinander.
- Schatten nur für Schwebendes (`shadow-popover`) und gedrückte Toolbar-Buttons (`shadow-raised`). Karten im Detail-Panel haben Hairline statt Schatten.
- Kein Element bekommt gleichzeitig Rahmen, Schatten und Füllung.

## Linien und Graph

- Stränge `stroke-strand` (2 px), runde Enden, Lane-Wechsel als weiche S-Kurve zwischen zwei Zeilenmitten.
- Commits sind Avatare im Strangring (24 px, Strich `stroke-strand`, Fallback Initialen); der Ring ist opak, keine Linie läuft hindurch. Merge-Commits sind gefüllte Punkte 11 px ohne Avatar.
- Stashes sind gestrichelte Quadrate mit gestrichelter Linie zum Basis-Commit und tragen kein Label links.
- Die WIP-Zeile hat einen gestrichelten Ring in `ink-muted`.
- Ref-Labels stehen rechtsbündig in der Spalte links vom Graphen: Strangfarbe als 16-%-Tint mit 1-px-Rahmen, Text und Glyphen in `ink`, nie weiße Schrift auf Vollfläche. Ein lokaler Branch und seine gleichnamigen Remotes teilen ein Label; monochrome Glyphen stehen alle im Label: zuerst eine Standort-Glyphe (Häkchen = hier ausgecheckt, Worktree-Glyphe = in anderem Worktree ausgecheckt, Laptop = lokal, nirgends ausgecheckt), dann eine Wolke je Remote.
- Namen im Text (Branches, Remote-Branches, Remotes, Tags, Commits, Dateipfade, Worktrees, Stashes) stehen nie in Anführungszeichen, sondern als kleine Pill: das Ref-Label der History im Kleinen, mit Glyphe (Laptop lokal, Wolke Remote, Etikett Tag, Ring Commit, Blatt Datei, Bonsai Worktree, Schale Stash) und in der Farbe der Art (`moss` lokal, `sky` Remote, `ochre` Tag, `clay` Worktree, `ink-muted` sonst) als 24-%-Tint. Commits immer mit dem 7-stelligen SHA, SHA und Pfad in `mono`. Das gilt für Menüs, Sheets, Banner, Toasts und Feldmeldungen; alle Texte entstehen über `RefString`/`RefText`. Die Pill behält in einer markierten Menüzeile ihre Farben. Namen über 220 pt werden in der Mitte gekürzt. Tooltips, Buttons und die Befehlsleiste nehmen nur Text an: dort steht der Name blank, ohne Anführungszeichen. Anführungszeichen bleiben für Prosa: Commit-Betreffs, Stash-Nachrichten, Kommandos und Eingaben des Nutzers.
- Lane-Wechsel sind enge S-Kurven: senkrecht auf der Lane, der Übergang liegt in einem 12-px-Fenster (`elbow`) um die Mitte zwischen zwei Zeilen. Zeilen-Bänder vom Knoten bis zur Strang-Linie der Textspalte, 13 % (HEAD 26 %), mit 5 px Abstand zwischen den Zeilen; die Textspalte bleibt ungetönt.

## Ikonografie

- Oberfläche: SF Symbols in Regular-Gewicht, Linienstärke `stroke-icon`, runde Enden. Keine gefüllten Varianten außer für Zustände (Konflikt, Fehler).
- Bonsai-Glyphen unter `assets/Icons` für alles, was ein Worktree ist: `bonsai-main` (Baum in Schale, der Hauptworktree), `bonsai-linked` (junger Baum in kleiner Schale, verknüpfter Worktree), `bonsai-locked` (Schale mit Band), `bonsai-detached` (Trieb im Wasserglas, detached HEAD), `bonsai-prunable` (kahler Trieb). Einfarbig in `ink`, als Badge in `clay`.
- `stash-bowl` (leere Schale) ist das Stash-Icon in Sidebar, Popover und Toolbar. Alle anderen Metaphern bleiben Git-Icons: Branch, Tag, Remote (Wolke), Laptop für lokal. Alle Glyphen monochrom in `currentColor`; der ausgecheckte Branch trägt überall dasselbe Häkchen, nie einen farbigen Punkt.

## Bewegung

- 160 ms ease-out für Hover und Auswahl, 220 ms für Popover und Sheets, keine Federung. Graph-Zeilen erscheinen ohne Animation; Nachladen ist unsichtbar.
- Während eines Drags friert das Layout ein; der Ghost ist ein Overlay mit 35 % Deckung, andere Stränge dimmen auf 35 %.
- `prefers-reduced-motion` schaltet alle Übergänge ab.

## Fenster und Panels

- **Drei Spalten**: Sidebar, History (Graph), Detail-Panel. Tabs in der Titelzeile, darunter die Toolbar: links Fetch-Status, in der Mitte die Aktionen, rechts die Suche.
- **Das Detail-Panel folgt der Auswahl in der History** und hat keinen Umschalter: ein Commit zeigt "Commit", die WIP-Zeile "Working Directory", ein Stash "Stash".
- **Diffs öffnen in der History-Spalte**, nie im Detail-Panel: eine Datei auswählen ersetzt den Graph durch ihren Diff (Kopf mit Zurück-Button "Graph", Dateiname, `+n −m`, Unified / Side by side, Hunk-Navigation). Hunks werden dort gestaged oder verworfen. Esc kehrt zum Graph zurück. Das Detail-Panel behält Dateiliste und Commit-Formular.
- **Author und Committer**: unterscheiden sich Name, E-Mail oder Datum, stehen beide Zeilen mit eigenem Datum da; ist alles identisch, eine Zeile "Author und Committer". Daten relativ, exakt im Tooltip.
- **SHAs**: der Commit-SHA ist ein Button, der den vollen SHA kopiert; jeder Parent-SHA ist ein Link, der zum Parent im Graph springt.
- **Zähler** wie `+18 −9` stehen immer einzeilig; bei Platzmangel kürzt sich der Pfad davor.
- **Keine erklärenden Sätze in Panels.** Was ein Klick tut, steht im Tooltip oder ergibt sich aus der Form.
- **WIP-Zeile**: nicht fett, nur Icons mit Zahlen (Stift geändert, Haken im Kreis staged, Plus untracked), Wörter im Tooltip.

## Drag-and-drop

- Während eines Drags wird nichts eingeschoben oder verschoben.
- Gedimmt wird pro Strang und Element, nie pro Zeile: voll sind der Quell-Strang auf ganzer Länge mit seinen Commits und die Spitze des Ziels (Knoten, Label mit Ring in `moss`, Textzeile); alles andere liegt bei 30 %. Ein Strang hat durchgehend eine Stärke.
- Das Ergebnis zeigt eine Karte neben dem Ziel: kleine Skizze mit gestrichelt gezeichnetem Neuen, ein Satz, das git-Kommando, der Hinweis auf ⌥ für Rebase.

## Liquid Glass

macOS 26 legt Toolbar, Sidebar, Sheets und Popover als Liquid Glass über den Inhalt. Glas widerspricht dem matten Bonsai-Bild nicht, solange es dort bleibt, wo das System es vorsieht, und der Inhalt selbst matt bleibt.

- **Glas nur für die Systemebene**: Toolbar, Tab-Leiste, Sidebar-Hintergrund, Sheets, Popover, Menüs. Diese Flächen nutzen das Standard-Glas des Systems (`NSGlassEffectView` bzw. `.glassEffect`), getönt mit `surface-1` bei etwa 60 % Deckung, damit das warme Papier durchscheint. Keine eigenen Blur-Werte, keine eigenen Highlights.
- **Der Graph ist nie Glas.** Er ist die Pflanze, nicht das Fenster: `surface-0`, matt, mit vollen Strangfarben. Beim Scrollen gleiten die Stränge unter der Glas-Toolbar hindurch; das ist der einzige Moment, in dem Glas das Konzept trägt, weil der Graph dann wie hinter einer Scheibe wächst.
- **Labels, Knoten, Banner und Detail-Panel bleiben matt.** Ein Label auf Glas verliert Kontrast; deshalb sitzen Ref-Labels im Graph-Bereich, nie in der Toolbar.
- **Tönung statt Farbe**: Glasflächen tragen nie `moss` oder `clay` als Tönung, nur Papier bzw. Rinde. Akzente bleiben opake Elemente auf dem Glas (Buttons, Badges), damit sie in jedem Hintergrund lesbar sind.
- **Fallback**: Mit "Transparenz reduzieren" werden dieselben Flächen opak `surface-1`; Layout und Abstände ändern sich nicht, nur die Materialität. Die Sidebar-Zeilenhöhen und Radien gelten auf beiden.

## Nicht

- Keine Verläufe, keine Glas-Effekte, keine farbigen Linksränder an Karten.
- Keine Emojis als Icons in der fertigen App; die Vorschauen hier nutzen sie nur als Platzhalter für SF Symbols.
- Keine zweite Akzentfarbe neben `moss` für Aktionen.
- Kein Bonsai-Bild in einem Dialog, der Daten löscht.
