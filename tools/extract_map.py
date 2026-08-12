#!/usr/bin/env python3
"""Extract a map disk into a flat tile grid for the Swift port.

Emits `<name>.map` — a tiny binary the app can mmap:

    magic   4 bytes  "7CMP"
    version 1 byte   = 1
    width   2 bytes  little endian
    height  2 bytes  little endian
    tiles   width*height bytes, one terrain nibble per byte, row major

Keeping one tile per byte rather than re-packing nibbles costs 100 KB and
saves every consumer from repeating the packing bug that cost days here.
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from map_preview import (  # noqa: E402
    sectors, deblock, crop_to_map, roll_columns, expand_nibbles,
)

MAGIC = b"7CMP"
VERSION = 1

TERRAIN = {
    0x0: "deepWater", 0x1: "mediumWater", 0x2: "shallowWater",
    0x3: "ship", 0x4: "riverJunction",
    0x5: "riverWE", 0x6: "riverNW", 0x7: "riverSW",
    0x8: "riverNS", 0x9: "riverNE", 0xA: "riverSE",
    0xB: "plain", 0xC: "forest", 0xD: "mountain",
    0xE: "swamp", 0xF: "village",
}


def extract(path, roll=1, first_track=13):
    img, w, h = deblock(sectors(path, first_track))
    img, w, h, top = crop_to_map(img, w, h)
    img = roll_columns(img, w, h, roll)
    tiles, width = expand_nibbles(img, w, h)
    return tiles, width, h, top


def main():
    src = sys.argv[1]
    dest = sys.argv[2] if len(sys.argv) > 2 else "map.map"
    tiles, w, h, top = extract(src)

    with open(dest, "wb") as f:
        f.write(MAGIC)
        f.write(struct.pack("<BHH", VERSION, w, h))
        f.write(tiles)

    counts = {TERRAIN[v]: tiles.count(v) for v in sorted(TERRAIN)}
    meta = {
        "source": os.path.basename(src),
        "width": w, "height": h, "croppedFromByteRow": top,
        "terrain": TERRAIN, "counts": counts,
    }
    with open(os.path.splitext(dest)[0] + ".json", "w") as f:
        json.dump(meta, f, indent=1)

    print(f"{os.path.basename(src)} -> {dest}: {w}x{h} = {w * h} tiles")
    for k, v in sorted(counts.items(), key=lambda kv: -kv[1]):
        if v:
            print(f"  {k:16s} {v:6d}  {100 * v / (w * h):5.1f}%")


if __name__ == "__main__":
    main()
