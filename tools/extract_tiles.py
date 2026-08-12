#!/usr/bin/env python3
"""Extract original terrain glyphs from a captured exploration frame.

The original has no tile atlas — it composes its viewport procedurally into
redefined characters — but the characters in a captured frame *are* genuine
rendered terrain, so representative ones can be lifted directly.

This is inherently approximate. The original draws mountains and some trees as
shapes spanning several cells, so no single 8x8 character holds a whole one;
what is picked here is the most representative fragment. "Original tiles" mode
shows the original's palette and pixel style faithfully, not a tileset the
original actually had — because it never had one.

Run `tools/boot_demo.py` first to capture a frame.

Emits `local/original_tiles.json`, which the viewer loads at runtime. It is
never committed: these are the original's pixels, unlike the RNG test vectors.

Viewport character codes run column-major from $70: code = $70 + col*12 + row.
"""
import json
import os
import sys

# Chosen by inspecting a rendered grid of all 144 viewport characters.
FROM_CAPTURE = {
    "deepWater": 0xD0,
    "mediumWater": 0xD0,
    "shallowWater": 0xC6,
    "plain": 0x88,
    "forest": 0x7D,
    "swamp": 0xB3,
    "mountain": 0x92,
    "ship": 0xC9,
}

# Not present in the captured frame. Drawn in the original's own 4-color 8x8
# multicolor grid so the set stays visually consistent, but these are
# reconstructions, not the original's pixels — the viewer labels them as such.
#
# Bit pairs: 0 = land, 1 = water, 2 = vegetation, 3 = detail(black)
def _row(pairs):
    return (pairs[0] << 6) | (pairs[1] << 4) | (pairs[2] << 2) | pairs[3]


RECONSTRUCTED = {
    "village": [_row(p) for p in [
        (0, 0, 0, 0), (0, 0, 3, 0), (0, 3, 3, 3), (0, 3, 0, 3),
        (0, 3, 0, 3), (0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0)]],
    "riverNS": [_row(p) for p in [(0, 1, 1, 0)] * 8],
    "riverWE": [_row(p) for p in
                [(0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0), (1, 1, 1, 1),
                 (1, 1, 1, 1), (0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0)]],
    "riverNW": [_row(p) for p in
                [(0, 1, 1, 0), (0, 1, 1, 0), (0, 1, 1, 0), (1, 1, 1, 0),
                 (1, 1, 1, 0), (0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0)]],
    "riverNE": [_row(p) for p in
                [(0, 1, 1, 0), (0, 1, 1, 0), (0, 1, 1, 0), (0, 1, 1, 1),
                 (0, 1, 1, 1), (0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0)]],
    "riverSW": [_row(p) for p in
                [(0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0), (1, 1, 1, 0),
                 (1, 1, 1, 0), (0, 1, 1, 0), (0, 1, 1, 0), (0, 1, 1, 0)]],
    "riverSE": [_row(p) for p in
                [(0, 0, 0, 0), (0, 0, 0, 0), (0, 0, 0, 0), (0, 1, 1, 1),
                 (0, 1, 1, 1), (0, 1, 1, 0), (0, 1, 1, 0), (0, 1, 1, 0)]],
    "riverJunction": [_row(p) for p in
                      [(0, 1, 1, 0), (0, 1, 1, 0), (0, 1, 1, 0), (1, 1, 1, 1),
                       (1, 1, 1, 1), (0, 1, 1, 0), (0, 1, 1, 0), (0, 1, 1, 0)]],
}

# Live values read from $D021/$D022/$D023 and color RAM during exploration.
# Color RAM held $8: bit 3 is the multicolor flag, so the foreground is 0.
PALETTE = {"bg0_land": 7, "bg1_water": 14, "bg2_vegetation": 5, "fg_detail": 0}


def main():
    charset = sys.argv[1] if len(sys.argv) > 1 else "local/exp_charset.bin"
    dest = sys.argv[2] if len(sys.argv) > 2 else "local/original_tiles.json"
    if not os.path.exists(charset):
        raise SystemExit(f"{charset} not found — run tools/boot_demo.py first")
    cs = open(charset, "rb").read()

    tiles, origin = {}, {}
    for name, code in FROM_CAPTURE.items():
        tiles[name] = list(cs[code * 8:code * 8 + 8])
        origin[name] = f"captured char ${code:02X}"
    for name, rows in RECONSTRUCTED.items():
        tiles[name] = rows
        origin[name] = "reconstructed"

    with open(dest, "w") as f:
        json.dump({"palette": PALETTE, "tiles": tiles, "origin": origin}, f, indent=1)

    captured = sum(1 for v in origin.values() if v.startswith("captured"))
    print(f"{dest}: {len(tiles)} tiles ({captured} captured, "
          f"{len(tiles) - captured} reconstructed)")
    for k in sorted(tiles):
        print(f"  {k:16s} {origin[k]}")


if __name__ == "__main__":
    main()
