#!/usr/bin/env python3
"""Chroma-key and split `scripts/art/source/marines_sheet.png` into sprites.

The sheet is ONE nano-banana render (`gemini-2.5-flash-image`, anchored on this
repo's own `data/soldier_red_front.png` as an `inline_data` style reference) so
the three pieces share a style with each other and with the starter's shipped
cog art. Committing the source render AND this script is the rule from
`playbooks/art-nanobanana.md`: the assets have to be reproducible, not
mysterious. CI does not regenerate art — the derived PNGs are committed too.

    python3 scripts/art/split_cog_sheet.py

writes, from left to right on the sheet:

    data/helm_red.png     the RED marine's visored helmet overlay
    data/helm_blue.png    the same helmet in the BLUE kit
    data/glyph_frag.png   the frag skull the kill feed, the `.beat-marker.kill`
                          marker and the endcard draw

Gemini returns no alpha and the "pure green" backdrop comes back as *some*
green with a tinted edge, so the key is a FLOOD FILL from the image border
(green accents inside a sprite survive) against the MEDIAN border colour
(corners sometimes carry a smudge).
"""

from __future__ import annotations

import os
import sys
from collections import deque

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SHEET = os.path.join(HERE, "source", "marines_sheet.png")

# Left to right on the sheet, with the square size each sprite is padded to.
PIECES = [
    ("helm_red.png", 128),
    ("helm_blue.png", 128),
    ("glyph_frag.png", 64),
]

TOLERANCE = 60          # per-channel distance from the backdrop that still keys
MIN_PIECE_WIDTH = 24    # ignore keying speckle when splitting on empty columns


def border_median(image: Image.Image) -> tuple[int, int, int]:
    """The backdrop colour, as the median of the whole image border."""
    w, h = image.size
    px = image.load()
    reds, greens, blues = [], [], []
    for x in range(w):
        for y in (0, h - 1):
            r, g, b = px[x, y][:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    for y in range(h):
        for x in (0, w - 1):
            r, g, b = px[x, y][:3]
            reds.append(r)
            greens.append(g)
            blues.append(b)
    mid = len(reds) // 2
    return (sorted(reds)[mid], sorted(greens)[mid], sorted(blues)[mid])


def key_backdrop(image: Image.Image) -> Image.Image:
    """Flood-fill the backdrop to transparent, starting from every border pixel."""
    rgba = image.convert("RGBA")
    w, h = rgba.size
    px = rgba.load()
    br, bg, bb = border_median(image)

    def is_backdrop(x: int, y: int) -> bool:
        r, g, b, _ = px[x, y]
        return abs(r - br) <= TOLERANCE and abs(g - bg) <= TOLERANCE and \
            abs(b - bb) <= TOLERANCE

    seen = bytearray(w * h)
    queue: deque[tuple[int, int]] = deque()
    for x in range(w):
        for y in (0, h - 1):
            queue.append((x, y))
    for y in range(h):
        for x in (0, w - 1):
            queue.append((x, y))
    while queue:
        x, y = queue.popleft()
        if x < 0 or y < 0 or x >= w or y >= h:
            continue
        if seen[y * w + x]:
            continue
        seen[y * w + x] = 1
        if not is_backdrop(x, y):
            continue
        px[x, y] = (0, 0, 0, 0)
        queue.extend(((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)))
    return rgba


def occupied_columns(image: Image.Image) -> list[bool]:
    w, h = image.size
    px = image.load()
    out = []
    for x in range(w):
        hit = False
        for y in range(h):
            if px[x, y][3] > 8:
                hit = True
                break
        out.append(hit)
    return out


def split_columns(image: Image.Image) -> list[tuple[int, int]]:
    """Column spans of the sprites, left to right."""
    cols = occupied_columns(image)
    spans: list[tuple[int, int]] = []
    start = None
    for x, filled in enumerate(cols + [False]):
        if filled and start is None:
            start = x
        elif not filled and start is not None:
            if x - start >= MIN_PIECE_WIDTH:
                spans.append((start, x))
            start = None
    return spans


def pad_square(image: Image.Image, size: int) -> Image.Image:
    """Trim to the sprite's own ink, then centre it in a transparent square."""
    box = image.getbbox()
    cropped = image.crop(box) if box else image
    side = max(cropped.size)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(cropped, ((side - cropped.width) // 2,
                           (side - cropped.height) // 2))
    return canvas.resize((size, size), Image.LANCZOS)


def main() -> int:
    if not os.path.exists(SHEET):
        print("missing sheet: " + SHEET, file=sys.stderr)
        return 1
    sheet = Image.open(SHEET)
    keyed = key_backdrop(sheet)
    spans = split_columns(keyed)
    if len(spans) != len(PIECES):
        print("expected %d sprites on the sheet, found %d: %r"
              % (len(PIECES), len(spans), spans), file=sys.stderr)
        return 1
    for (name, size), (x0, x1) in zip(PIECES, spans):
        piece = pad_square(keyed.crop((x0, 0, x1, keyed.height)), size)
        out = os.path.join(ROOT, "data", name)
        piece.save(out)
        print("wrote %s (%dx%d)" % (out, size, size))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
