# Design

The design sources of GitBonsai:

- [design-language.md](design-language.md) — principles, voice, colour, typography, form, graph, iconography, motion, windows and panels.
- [tokens.json](tokens.json) — the shared scales: colours (light and dark), typography, spacing, radii, shadows, strokes, icon sizes, washes and focus dimming. `Sources/GitBonsai/DesignTokens.swift` (`Theme`) mirrors every scale; sizes that belong to one component live only in its namespace there (`Theme.Tabs`, `Theme.Sidebar`, `Theme.Graph`, …). Change a shared value in both places.
- [ref-text.md](ref-text.md) — the study behind names as inline pills in menus, sheets and banners.
- [icons/](icons/README.md) — bonsai glyphs for worktree states, the stash bowl, the laptop and the empty-state drawing.
- [app-icon/](app-icon/README.md) — the app icon as an Icon Composer document with one SVG per layer; concept, layers and colours in its README.
