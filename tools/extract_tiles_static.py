#!/usr/bin/env python3
"""Extract the original terrain tiles from the disk, with no emulator.

The exploration view draws terrain as **redefined characters**, which is why
the charset is not stored anywhere on either disk and why an earlier attempt
had to capture it from a running game. But the tile *bitmaps* are static data
inside the main program — it is only the charset that is assembled at runtime.
Decrypt `game` and they can be read straight out (see NOTES.md).

How the view is built, recovered from the decrypted program:

    $3107  lay out a 12x12 grid of unique character codes in the video matrix,
           code = $70 + row + col * $0C, then fill color RAM with $08
           (multicolor flag + color 0)
    $31B4  point $B1/$B2 at the charset glyph region and walk 6x6 map tiles,
           advancing $C0 per tile column (2 char columns) and $10 per tile row
    $58B8  per tile: read the map byte, split it into a low nibble (base
           terrain) and a high nibble (overlay), and dispatch through the
           pointer table at $5529

So one map tile is **2x2 characters = 32 bytes**, and `$5529` gives the pattern
address for each of the 16 terrain values. Water is the exception: entries 0 and
2 point at `$94B0`, a RAM buffer the game animates, so those are drawn as flat
color here.

Palette, from the setup at `$32C0` and the raster IRQ at `$2250` that copies the
shadow bytes into the VIC registers:

    00 -> $D021 = $07  yellow   (plains)
    01 -> $D022 = $0E  light blue (water)
    10 -> $D023 = $05  green    (vegetation)
    11 -> color RAM $08 & $07 = 0, black (rock and outlines)

    tools/extract_tiles_static.py --png local/original_tiles.png
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decrypt_game import decrypt  # noqa: E402

BASE = 0x0800
DISPATCH = 0x5529
TILE_BYTES = 32

# C64 colors, Pepto palette
C64 = {0x00: (0x00, 0x00, 0x00), 0x05: (0x58, 0x8D, 0x43),
       0x07: (0xB8, 0xC7, 0x6F), 0x0E: (0x6C, 0x5E, 0xB5)}
PALETTE = [C64[0x07], C64[0x0E], C64[0x05], C64[0x00]]

NAMES = ["deepWater", "mediumWater", "shallowWater", "ship", "riverJunction",
         "riverWE", "riverNW", "riverSW", "riverNS", "riverNE", "riverSE",
         "plain", "forest", "mountain", "swamp", "village"]

ANIMATED = {0, 1, 2}        # water entries point at a RAM buffer, not a pattern


def tile_pixels(data, addr):
    """A 2x2-character multicolor tile as 8x16 palette indices.

    The four glyphs are stored in the order the composer writes them, which
    follows the video matrix layout `code = $70 + row + col * $0C`: down the
    left column first, then down the right.
    """
    raw = data[addr - BASE:addr - BASE + TILE_BYTES]
    px = [[0] * 8 for _ in range(16)]
    for g in range(4):
        col, row = g // 2, g % 2
        for y in range(8):
            v = raw[g * 8 + y]
            for i in range(4):
                px[row * 8 + y][col * 4 + i] = (v >> (6 - i * 2)) & 3
    return px


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--game", default="local/game.bin",
                   help="the encrypted `game` file, load address stripped")
    p.add_argument("--png")
    p.add_argument("--json")
    a = p.parse_args()

    data = decrypt(open(a.game, "rb").read())
    table = data[DISPATCH - BASE:DISPATCH - BASE + 32]
    out = {}
    for i, name in enumerate(NAMES):
        addr = table[i * 2] | table[i * 2 + 1] << 8
        if i in ANIMATED:
            out[name] = {"address": addr, "animated": True,
                         "pixels": [[1] * 8 for _ in range(16)]}
        else:
            out[name] = {"address": addr, "animated": False,
                         "pixels": tile_pixels(data, addr)}
        print(f"  {i:2d} ${i:X}  ${addr:04X}  {name}"
              + ("   (animated water)" if i in ANIMATED else ""))

    if a.json:
        json.dump(out, open(a.json, "w"), indent=1)
        print(f"wrote {a.json}")
    if a.png:
        from PIL import Image
        sc, w = 6, 8
        img = Image.new("RGB", (len(NAMES) * (w * sc + 4), 16 * sc), (30, 30, 30))
        for n, name in enumerate(NAMES):
            for y, rowpx in enumerate(out[name]["pixels"]):
                for x, v in enumerate(rowpx):
                    for dy in range(sc):
                        for dx in range(sc):
                            img.putpixel((n * (w * sc + 4) + x * sc + dx,
                                          y * sc + dy), PALETTE[v])
        img.save(a.png)
        print(f"wrote {a.png}")


if __name__ == "__main__":
    main()
