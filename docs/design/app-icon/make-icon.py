#!/usr/bin/env python3
"""Writes AppIcon.icon, the Icon Composer document of the GitBonsai app icon.

Every colour comes from docs/design/tokens.json by token name; the few icon-only shades are named below.
Run it after changing a shape or colour here; Icon Composer can open and fine-tune the result.
"""
import json
import pathlib
import shutil

HERE = pathlib.Path(__file__).resolve().parent
TOKENS = json.loads((HERE.parent / "tokens.json").read_text())
DOC = HERE / "AppIcon.icon"


def token(name, mode):
    def find(node):
        if isinstance(node, dict):
            if node.get("name") == name and isinstance(node.get("value"), dict):
                return node["value"][mode]
            node = list(node.values())
        if isinstance(node, list):
            for child in node:
                found = find(child)
                if found:
                    return found
        return None
    value = find(TOKENS)
    if value is None:
        raise SystemExit(f"token {name} missing in tokens.json")
    return value


# Icon-only shades: the bowl rim and bark have no UI token; the background runs from surface-0 to a deeper paper.
SHADES = {
    "bark": {"light": "#5b4433", "dark": "#c9b49c"},
    "clay-rim": {"light": "#86432a", "dark": "#c47f60"},
    "paper-top": {"light": "#fbf8f3", "dark": "#2c2621"},
    "paper-bottom": {"light": "#efe4d4", "dark": "#191512"},
}


def color(name, mode):
    return SHADES[name][mode] if name in SHADES else token(name, mode)


def srgb(hex_color):
    h = hex_color.lstrip("#")
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def svg(body):
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">\n{body}</svg>\n'


# --- Layers on the 1024 pt canvas. The tree grows like the history graph: lanes with S-curves, commits at the tips.

LEAF_PAIR = ('<path d="M500 470 C380 470 280 380 290 220 C440 220 520 330 500 470 Z"/>'
             '<path d="M524 470 C640 470 750 400 744 250 C600 250 510 340 524 470 Z"/>')

# (x, y, scale, rotation): a pair of leaves sprouting at x/y, the big ones behind each commit.
LEAF_PAIRS = [
    (418, 478, 0.42, -50), (636, 448, 0.40, 55), (548, 418, 0.44, -18),
    (262, 468, 0.36, -80), (790, 520, 0.34, 80), (660, 268, 0.42, 40),
    (342, 432, 0.62, -28), (714, 498, 0.56, 28), (590, 300, 0.78, 0),
]

COMMITS = [(342, 432, 46, "strand-persimmon"), (714, 498, 42, "strand-sky"), (590, 300, 56, "strand-ochre")]


def leaves(mode):
    fill = color("moss", mode)
    pairs = "".join(
        f'  <g transform="translate({x} {y}) rotate({r}) scale({s}) translate(-512 -470)">{LEAF_PAIR}</g>\n'
        for x, y, s, r in LEAF_PAIRS
    )
    return f'<g fill="{fill}">\n{pairs}</g>\n'


def trunk(mode):
    stroke = color("bark", mode)
    style = f'fill="none" stroke="{stroke}" stroke-linejoin="round"'
    # The trunk ends flat at the top edge of the bowl rim, so no part of it lies under the bowl.
    return (f'<path d="M512 666 V600 C512 572 470 560 470 530 V500 C470 470 520 455 540 430 C560 405 590 380 590 320" stroke-width="56" {style} stroke-linecap="butt"/>\n'
            f'<path d="M478 520 C440 500 360 480 342 432" stroke-width="36" stroke-linecap="round" {style}/>\n'
            f'<path d="M540 430 C600 440 690 470 714 498" stroke-width="32" stroke-linecap="round" {style}/>\n')


def bowl(mode):
    body, rim = color("clay", mode), color("clay-rim", mode)
    return (f'<path d="M232 690 H792 Q800 690 798 700 L760 812 Q754 832 732 832 H292 Q270 832 264 812 L226 700 Q224 690 232 690 Z" fill="{body}"/>\n'
            f'<rect x="212" y="664" width="600" height="44" rx="22" fill="{rim}"/>\n'
            f'<rect x="318" y="826" width="64" height="34" rx="12" fill="{body}"/>\n'
            f'<rect x="642" y="826" width="64" height="34" rx="12" fill="{body}"/>\n')


def commits(mode):
    ring = token("surface-0", mode) if mode == "light" else token("ink", "dark")
    return "".join(
        f'<circle cx="{x}" cy="{y}" r="{r}" fill="{token(name, mode)}" stroke="{ring}" stroke-width="22"/>\n'
        for x, y, r, name in COMMITS
    )


# Front-most group first, as Icon Composer stores them. Commits and bowl are opaque (no translucency): leaves and trunk never show through them.
GROUPS = [
    ("commits", commits, None),
    ("bowl", bowl, None),
    ("trunk", trunk, 0.4),
    ("leaves", leaves, 0.5),
]


def gradient(mode):
    return {
        "linear-gradient": [srgb(color("paper-top", mode)), srgb(color("paper-bottom", mode))],
        "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}},
    }


def main():
    shutil.rmtree(DOC, ignore_errors=True)
    (DOC / "Assets").mkdir(parents=True)
    groups = []
    for name, draw, translucency in GROUPS:
        for mode, suffix in (("light", ""), ("dark", "-dark")):
            (DOC / "Assets" / f"{name}{suffix}.svg").write_text(svg(draw(mode)))
        groups.append({
            "name": name,
            "layers": [{
                "name": name,
                "glass": True,
                "image-name-specializations": [
                    {"value": f"{name}.svg"},
                    {"appearance": "dark", "value": f"{name}-dark.svg"},
                ],
            }],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "specular": True,
            "translucency": {"enabled": translucency is not None, "value": translucency or 0.5},
        })
    document = {
        "fill-specializations": [{"value": gradient("light")}, {"appearance": "dark", "value": gradient("dark")}],
        "groups": groups,
        "supported-platforms": {"squares": ["macOS"]},
    }
    (DOC / "icon.json").write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
