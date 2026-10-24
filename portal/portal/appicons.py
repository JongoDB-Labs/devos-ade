"""The DevOS ADE mark and every icon drawn from it: the DevOS torus with its ribbon in teal, on a black tile (the
DevOS Companion's and DevOS Mobile's icon, the ribbon's colour its own).

The source is a picture, not a drawing: portal/brand/AppIcon.icon/Assets/torus-teal.png (the torus on transparent;
AppIcon.icon is the same Icon Composer bundle as the DevOS apps', for a macOS app). `portal/render-icons.sh` (in the
repo's portal/ folder) runs `python -m portal.appicons`, which composes each PNG of static/icons/ from it with Pillow
(LANCZOS for the torus, the tile's edge drawn at 4x and scaled down), writes static/brand/glyph.svg and
static/logo.svg (the favicon and the sidebar's logo: the small icon as an SVG around a PNG), and records the Pillow
version and the sha256 of the source and of every file it wrote in static/icons/SOURCES — so the tests can tell when
an icon is stale or was edited by hand. Importing this module needs no Pillow (the portal only reads FILES).

Each kind places the torus on its tile:
  icon      macOS-style squircle (824 px body on the 1024 grid, transparent margin): the master, and the PWA "any" icons
  maskable  full-bleed square, the torus inside the central safe circle (radius 40 %) that every mask keeps
  apple     full-bleed square for iOS (it rounds the corners itself)
  glyph     the whole square a squircle, the torus larger: 16-48 px, the favicon and the sidebar logo
  mono      the torus's silhouette in black on transparent, for the manifest's "monochrome" purpose
"""

from __future__ import annotations

import base64
import hashlib
import io
import math
import sys
from pathlib import Path

STATIC = Path(__file__).parent / "static"
BRAND = STATIC / "brand"
ICON_DIR = STATIC / "icons"
# The source (outside the image: the repository's portal/brand/); render-icons.sh runs this from portal/
SOURCE = Path(__file__).resolve().parent.parent / "brand" / "AppIcon.icon" / "Assets" / "torus-teal.png"

# Published PNG -> (size in px, kind). /icons/app-<rest>.png serves exactly these.
FILES = {
    "app-16.png": (16, "glyph"),
    "app-32.png": (32, "glyph"),
    "app-48.png": (48, "glyph"),
    "app-192.png": (192, "icon"),
    "app-512.png": (512, "icon"),
    "app-1024.png": (1024, "icon"),
    "app-maskable-192.png": (192, "maskable"),
    "app-maskable-512.png": (512, "maskable"),
    "app-monochrome-512.png": (512, "mono"),
    "app-touch-180.png": (180, "apple"),
}
# The SVGs: the glyph at GLYPH_SVG_PX inside an SVG (the sidebar shows it at 28-36 px: sharp at 3x). logo.svg is
# the sidebar/login logo and /favicon.svg, the same file as brand/glyph.svg.
SVGS = (BRAND / "glyph.svg", STATIC / "logo.svg")
GLYPH_SVG_PX = 128

# Which kinds fill the whole square (opaque corners) vs keep transparent corners.
FULL_BLEED = {"maskable", "apple"}
TILE = (0, 0, 0)

# kind -> (the torus's width as a share of the square, the tile: (half its side as a share of the square, its
# superellipse exponent), or None for the whole square)
PLACE = {
    "icon": (0.8 * 824 / 1024, (412 / 1024, 5.0)),   # icon.json's scale 0.8, on macOS's 824 px tile
    "maskable": (0.73, None),                         # its farthest pixel 0.39 of the side from the centre
    "apple": (0.8, None),
    "glyph": (0.9, (0.5, 4.2)),
    "mono": (0.73, None),
}


def _superellipse(cx: float, cy: float, half: float, n: float, steps: int = 720) -> list[tuple[float, float]]:
    """|x|^n + |y|^n = 1, scaled: close to the continuous-corner tile of macOS / iOS icons."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append((cx + half * math.copysign(abs(c) ** (2 / n), c), cy + half * math.copysign(abs(s) ** (2 / n), s)))
    return pts


def render(kind: str, size: int, torus):
    """One icon: a Pillow RGBA image of SIZE px."""
    from PIL import Image, ImageDraw

    share, tile = PLACE[kind]
    if tile is None:
        mask = Image.new("L", (size, size), 255)
    else:
        big = size * 4
        m = Image.new("L", (big, big), 0)
        ImageDraw.Draw(m).polygon(_superellipse(big / 2, big / 2, tile[0] * big, tile[1]), fill=255)
        mask = m.resize((size, size), Image.LANCZOS)
    w = max(1, round(size * share))
    h = max(1, round(torus.height * w / torus.width))
    t = torus.resize((w, h), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    if kind == "mono":
        out.paste(Image.new("RGBA", t.size, (0, 0, 0, 255)), ((size - w) // 2, (size - h) // 2), t.getchannel("A"))
        return out
    out.paste(Image.new("RGBA", (size, size), TILE + (255,)), (0, 0), mask)
    out.alpha_composite(t, ((size - w) // 2, (size - h) // 2))
    return out


def _png(img) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def glyph_svg(png: bytes) -> str:
    b64 = base64.b64encode(png).decode()
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {GLYPH_SVG_PX} {GLYPH_SVG_PX}">'
            f'<image width="{GLYPH_SVG_PX}" height="{GLYPH_SVG_PX}" href="data:image/png;base64,{b64}"/></svg>')


def main() -> None:
    import PIL
    from PIL import Image

    torus = Image.open(SOURCE).convert("RGBA")
    sha = lambda b: hashlib.sha256(b).hexdigest()  # noqa: E731
    lines = [f"# Pillow {PIL.__version__}", f"{sha(SOURCE.read_bytes())}  brand/AppIcon.icon/Assets/torus-teal.png"]
    ICON_DIR.mkdir(parents=True, exist_ok=True)
    for name, (size, kind) in FILES.items():
        data = _png(render(kind, size, torus))
        (ICON_DIR / name).write_bytes(data)
        lines.append(f"{sha(data)}  icons/{name}")
    svg = glyph_svg(_png(render("glyph", GLYPH_SVG_PX, torus))) + "\n"
    for path in SVGS:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(svg)
    lines.append(f"{sha(svg.encode())}  brand/glyph.svg")
    (ICON_DIR / "SOURCES").write_text("\n".join(lines) + "\n")
    print(f"wrote {len(FILES)} icons, {len(SVGS)} SVGs and SOURCES from {SOURCE.name}", file=sys.stderr)


if __name__ == "__main__":
    main()
