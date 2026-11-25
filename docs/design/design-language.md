# Design language

GitBonsai is a native macOS git client. Its design follows the bonsai: calm, warm, crafted, patient. Nothing blinks, nothing pushes. The graph is the plant, the interface is the bowl.

Token names below refer to [tokens.json](tokens.json), which `Sources/GitBonsai/DesignTokens.swift` mirrors.

## Principles

1. **Warm, not neutral.** Every surface and every grey carries a trace of bark or paper. Pure white only for popovers and input fields (`surface-2`), pure black nowhere.
2. **Soft, but precise.** Round caps, round rings, pills; but exact 1 px hairlines and clear columns. The form is soft, not the information.
3. **The graph is the main figure.** Colour belongs to the strands first. Chrome, sidebar and text stay in paper and ink so that the graph shines.
4. **One metaphor, used sparingly.** Bonsai images and words appear in the brand, empty states and worktree icons. The working interface speaks git: Branch, Rebase, Stash, Worktree.
5. **No noise.** No AI buttons, no ads, no badges without meaning. Every highlight says something about the state of the repository.

## Voice and text

- English is the development language of the interface and of all documentation; German is the first translation. Git terms stay as git users know them in every language ("Rebase auf main", not a translated verb).
- Calm, complete sentences. No exclamation marks, no emoji in the interface. Commands follow the capitalization rule in `AGENTS.md`: the verb and the git object capitalized ("Checkout Commit", "Create annotated Tag…").
- Labels of actions (buttons, menu items, banner actions) are always one line; when space is short the explanatory text is shortened, never the action wrapped.
- Errors show the complete git output in monospace (`code`) under a short sentence that says what to do.
- The metaphor may speak in empty states and onboarding, but only with the word bonsai and the git terms; gardening vocabulary does not appear in the interface. No metaphor in dialogs.

## Colour

- Surfaces: `surface-0` for window and graph, `surface-1` for sidebar, toolbar, tabs and status line, `surface-2` for everything that floats above. Separators are always `hairline`.
- Text: `ink` on all surfaces; `ink-muted` for author, date, counts; `ink-faint` only for dimmed commits outside the current branch and only from 13 px.
- Accent: `moss` is the only primary colour. Primary button, links, active tab, focus ring, checked-out branch. Text on `moss` in `on-moss`.
- `clay` marks worktrees and crafting interventions (rebase banner, worktree badges). Never a second primary accent for buttons.
- States: `ochre` warns, `persimmon` endangers, `sky` informs; each with its `-soft` fill as background. A state always carries a word or icon too, never colour alone.
- Graph strands: the twelve `strand-*` colours in their given order, cycling, so that neighbouring strands never share a hue family. In dark mode they are deliberately muted; the line carries the colour, not the fill.
- Dark mode is not inverted light: strands get lighter and slightly desaturated, accents become light fills with dark text (`on-moss`).

## Typography

- Interface in the system font (`ui`, SF Pro): `body` 13/18 for everything readable, `body-strong` for HEAD, the active worktree and the checked-out branch, `caption` for author, date and counts, `label` in capitals for section titles and column headers.
- Brand in `display` (Fraunces, soft, with optical size): `wordmark` and `display` only in onboarding, About, the website and empty states. Never in lists, dialogs or the toolbar.
- Code in `mono`: diffs, the command line in the status line, paths, SHAs (`sha` in lists). Tabular figures wherever numbers stand above one another. Times are relative ("yesterday", "1 week ago"), the exact timestamp in the tooltip.

## Form and space

- Radii: `radius-sm` for buttons and fields, `radius-md` for tabs, popovers and banners, `radius-lg` for sheets, `radius-pill` for every label. The stash node is the only square (`radius-xs`).
- Spacing from the 4 px scale. Graph rows are `row` (36 px) high and lanes `lane` (28 px) apart; sidebar rows are 26 px.
- Shadows only for floating elements (`shadow-popover`) and pressed toolbar buttons (`shadow-raised`). Cards in the detail panel have a hairline instead of a shadow.
- No element gets border, shadow and fill at once.

## Lines and graph

- Strands `stroke-strand` (2 px), round caps; a lane change is a tight S curve: vertical on the lane, with the transition inside a 12 px window (`elbow`) around the middle between two rows.
- Commits are avatars in the strand ring (`node`, 24 px, stroke `stroke-strand`, initials as fallback); the ring is opaque, no line runs through it. Merge commits are filled dots without avatar.
- Stashes are dashed squares with a dashed line to their base commit and carry no label on the left.
- The working directory row has a dashed ring in `ink-muted`.
- Row bands run from the node to the strand line of the text column, 13 % (HEAD 26 %), with 5 px between rows; the text column stays untinted.
- Ref labels stand right-aligned in the column left of the graph: the strand colour as a 16 % tint with a 1 px border, text and glyphs in `ink`, never white text on a solid fill. A local branch and its remote branches of the same name share a label; its monochrome glyphs come first a location glyph (check mark: checked out here; worktree glyph: checked out in another worktree; laptop: local, checked out nowhere), then a cloud per remote.
- Names in running text (branches, remote branches, remotes, tags, commits, file paths, worktrees, stashes) never stand in quotes but as small pills: the history's ref label in small, with a glyph (laptop local, cloud remote, tag, ring commit, leaf file, bonsai worktree, bowl stash) in the colour of the kind (`moss` local, `sky` remote, `ochre` tag, `clay` worktree, `ink-muted` otherwise) as a 24 % tint. Commits always with the 7-character SHA, SHA and path in `mono`. This holds for menus, sheets, banners, toasts and field messages; all texts are built through `RefString` and `RefText`. The pill keeps its colours in a highlighted menu row. Names over 220 pt are shortened in the middle. Tooltips, buttons and the command bar take plain text only: there the name stands bare, without quotes. Quotes remain for prose: commit subjects, stash messages, commands and user input. The study behind this is [ref-text.md](ref-text.md).

## Iconography

- Interface: SF Symbols in regular weight, line width `stroke-icon`, round caps. No filled variants except for states (conflict, error).
- Bonsai glyphs in [icons/](icons/README.md) for everything that is a worktree: `bonsai-main` (tree in a bowl, the main worktree), `bonsai-linked` (young tree in a small bowl, linked worktree), `bonsai-locked` (bowl with a band), `bonsai-detached` (shoot in a water glass, detached HEAD), `bonsai-prunable` (bare shoot). Monochrome in `ink`, as a badge in `clay`.
- `stash-bowl` (an empty bowl) is the stash icon in the sidebar, popover and toolbar. All other metaphors stay git icons: branch, tag, remote (cloud), laptop for local. All glyphs monochrome in `currentColor`; the checked-out branch carries the same check mark everywhere, never a coloured dot.

## Motion

- 160 ms ease-out for hover and selection, 220 ms for popovers and sheets, no spring. Graph rows appear without animation; loading more is invisible.
- Reduce Motion turns all transitions off.

## Window and panels

- **Three columns**: sidebar, history (graph), detail panel. Tabs in the title bar, the toolbar below: fetch on the left, the actions in the middle, the search on the right.
- **The detail panel follows the selection in the history** and has no switcher: a commit shows the commit, the working directory row the working directory, a comparison its files, a stash the stash.
- **Diffs open in the history column**, never in the detail panel: selecting a file replaces the history with its diff (header with change letter, path, "Diff | File", hunk navigation and a close button). Hunks are staged or discarded there. The detail panel keeps the file list and the commit form.
- **Author and committer**: when name, email or date differ, both lines stand with their own date; when all match, one line. Dates relative, exact in the tooltip.
- **SHAs**: the commit SHA has a button that copies the full SHA; every parent SHA is a link to the parent in the graph.
- **Counts** such as `+18 −9` always stay on one line; when space is short the path before them is shortened.
- **No explanatory sentences in panels.** What a click does is in the tooltip or follows from the form.
- **Working directory row**: not bold, only icons with counts (pencil modified, check in a circle staged, plus untracked), words in the tooltip.

## Drag and drop (planned)

Not built yet; the backlog tracks it. The design:

- While dragging nothing is inserted or moved, and the layout is frozen.
- Dimming is per strand and element, never per row: fully visible are the source strand over its whole length with its commits and the target's tip (node, label with a ring in `moss`, text row); everything else is at 30 %. A strand keeps one strength throughout.
- The result shows as a card next to the target: a small sketch with the new parts dashed, one sentence, the git command, and the hint that ⌥ switches to rebase.

## Liquid Glass

macOS 26 lays toolbar, sidebar, sheets and popovers as Liquid Glass over the content. Glass does not contradict the matte bonsai image as long as it stays where the system puts it and the content itself stays matte.

- **Glass only for the system layer**: toolbar, tab row, sidebar background, sheets, popovers, menus, the command bar. These use the system's standard glass, tinted with `surface-1` so that the warm paper shows through. No custom blur values, no custom highlights.
- **The graph is never glass.** It is the plant, not the window: `surface-0`, matte, with full strand colours. When scrolling, the strands glide under the glass toolbar.
- **Labels, nodes, banners and the detail panel stay matte.** A label on glass loses contrast; ref labels therefore sit in the graph area, never in the toolbar.
- **Tint, not colour**: glass surfaces never carry `moss` or `clay` as tint, only paper or bark. Accents stay opaque elements on the glass (buttons, badges) so they are readable on any background.
- **Fallback**: with Reduce Transparency the same surfaces become opaque `surface-1`; layout and spacing do not change.

## Never

- No gradients, no glass outside the system layer, no coloured left borders on cards.
- No emoji as icons.
- No second accent colour next to `moss` for actions.
- No bonsai image in a dialog that deletes data.
