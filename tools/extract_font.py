#!/usr/bin/env python3
"""Extract the game's 8x8 font from disk 1's raw sector region.

The font is 96 characters in ASCII order starting with space, at offset 4714
($126A) of the raw stream from tracks 1-10. It is NOT PETSCII order, which is
why the game's text tables index it as `character = ASCII - $20`.

Note the loader only ever reads sectors 0-19 of each track, so the stream must
be built that way or every offset after track 1 is wrong.
"""
import json
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from d64 import D64  # noqa: E402

FONT_OFFSET = 4713        # ground-truthed against a live charset dump
GLYPHS = 96
FIRST_CHAR = 0x20         # space


def raw_stream(path, first=1, last=10, per_track=20):
    d = D64(path)
    buf = bytearray()
    for t in range(first, last + 1):
        for s in range(per_track):
            buf += d.sector(t, s)
    return bytes(buf)


def glyphs(stream, offset=FONT_OFFSET, count=GLYPHS):
    return [stream[offset + i * 8:offset + i * 8 + 8] for i in range(count)]


def verify(gs):
    """Sanity-check the offset rather than trusting it blindly."""
    if any(gs[0]):
        raise SystemExit("glyph 0 (space) is not blank — wrong offset")
    letters = sum(1 for i in range(33, 59) if gs[i][7] == 0 and any(gs[i][1:7]))
    if letters < 20:
        raise SystemExit(f"only {letters}/26 letters look like glyphs — wrong offset")
    return letters


def atlas(gs, path, scale=4, per_row=16):
    rows = (len(gs) + per_row - 1) // per_row
    im = Image.new("RGB", (per_row * 8, rows * 8), (0, 0, 0))
    px = im.load()
    for i, g in enumerate(gs):
        ox, oy = (i % per_row) * 8, (i // per_row) * 8
        for y in range(8):
            for x in range(8):
                if g[y] & (0x80 >> x):
                    px[ox + x, oy + y] = (255, 255, 255)
    im.resize((per_row * 8 * scale, rows * 8 * scale),
              Image.NEAREST).save(path)
    return im.size


def main():
    disk = sys.argv[1] if len(sys.argv) > 1 else "d64/7CITIES1.D64"
    outdir = sys.argv[2] if len(sys.argv) > 2 else "local"
    stream = raw_stream(disk)
    gs = glyphs(stream)
    letters = verify(gs)

    png = os.path.join(outdir, "font.png")
    atlas(gs, png)
    data = {
        "source": os.path.basename(disk),
        "offset": FONT_OFFSET,
        "glyphs": GLYPHS,
        "order": "ASCII from space; character index = ASCII - 0x20",
        "bitmaps": {chr(FIRST_CHAR + i): list(g) for i, g in enumerate(gs)},
    }
    js = os.path.join(outdir, "font.json")
    with open(js, "w") as f:
        json.dump(data, f, indent=1)
    print(f"font: {GLYPHS} glyphs at offset {FONT_OFFSET} (${FONT_OFFSET:04X}), "
          f"{letters}/26 letters verified")
    print(f"  -> {png}\n  -> {js}")


if __name__ == "__main__":
    main()
