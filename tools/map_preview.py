#!/usr/bin/env python3
"""Render a Seven Cities of Gold map disk to a PNG.

The map is stored *blocked* and *packed*, which took several passes to get
right. Every 256-byte sector is a 16x16 block of bytes; blocks tile 8 per row
(the source row stride is $80 = 128 tiles, and a block is 16 wide); a sector is
split into left and right column halves rather than being row-major; and every
byte holds two horizontally adjacent tiles as nibbles. The finished map is
256 tiles wide by 400 tall.

Reading it as row-major bytes smeared land into horizontal streaks and made
every stride search fail, because there is no single row stride to find.
"""
import collections
import os
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from d64 import D64, sectors_per_track  # noqa: E402

BLOCK = 16
BLOCKS_PER_ROW = 8       # source row stride $80 = 128 tiles / 16 per block
PADDING = 0x01          # untouched filler outside the map proper

# Each byte holds TWO horizontally adjacent tiles, high nibble first. This is
# why the address calculator at $0EE4 multiplies the low nibble by 2, and why
# values pair up the way they do: $BB is two land tiles, $00 two ocean, and
# $B0 / $0B are land+ocean — a coastline, nibble-swapped for which side the
# water is on. The map is therefore 256 tiles wide, not 128.
#
# Nibble semantics, established by diffing the map buffer at $5700 across
# generation phases (see tools/wm_trace.py):
#
#   land-mass phase writes  $00, $BB, $B0, $0B      -> ocean, land, coastline
#   terrain phase writes    $11, $BC, $CB, $CC, ... -> shelf and terrain classes
#   village phase writes    $BF, $FB, $FC, $CF, ... -> sites (F = marker nibble)
NIBBLE = {
    0x0: (12, 34, 102),     # ocean            (confirmed: land-mass phase)
    0x1: (30, 60, 140),     # continental shelf / shallows
    0xB: (74, 150, 64),     # land / plain     (confirmed: land-mass phase)
    0xC: (150, 160, 70),    # ? scrub or hills
    0xD: (140, 120, 80),    # ? highland
    0xE: (130, 130, 135),   # ? mountain
    0xF: (240, 240, 240),   # ? site marker    (village phase)
    0x2: (60, 120, 190),
    0x3: (90, 170, 210),
    0x4: (110, 140, 200),
    0x5: (200, 170, 90),
    0x6: (80, 150, 170),
    0x7: (100, 160, 120),
    0x8: (120, 170, 90),
    0x9: (170, 180, 80),
    0xA: (190, 150, 70),
}
UNKNOWN = (230, 60, 200)


def sectors(path, first_track=13):
    d = D64(path)
    out = []
    for t in range(first_track, 36):
        for s in range(min(20, sectors_per_track(t))):
            out.append(d.sector(t, s))
    return out


def deblock(secs):
    """Un-tile the 16x16 blocks into a flat row-major image.

    A sector is NOT row-major within the block. Tracing X through the assembly
    loop at $0F54: each outer pass writes 8 tiles to $0200+8i and 8 more to
    $0278+8i+8 == $0280+8i. So the sector splits as

        bytes $00-$7F : left 8 columns of all 16 rows
        bytes $80-$FF : right 8 columns of all 16 rows

    Reading it row-major scrambles the columns inside every block.
    """
    rows = (len(secs) + BLOCKS_PER_ROW - 1) // BLOCKS_PER_ROW
    w, h = BLOCKS_PER_ROW * BLOCK, rows * BLOCK
    img = bytearray(PADDING for _ in range(w * h))
    for i, sec in enumerate(secs):
        bx = (i % BLOCKS_PER_ROW) * BLOCK
        by = (i // BLOCKS_PER_ROW) * BLOCK
        for r in range(BLOCK):
            off = (by + r) * w + bx
            img[off:off + 8] = sec[r * 8:r * 8 + 8]              # left half
            img[off + 8:off + 16] = sec[0x80 + r * 8:0x80 + r * 8 + 8]
    return bytes(img), w, h


def crop_to_map(img, w, h):
    """Trim to the block-rows that actually hold terrain.

    Keeping every non-padding row is not enough: both disks carry other
    structures outside the map proper, and the historical disk has a whole
    region above the map that is neither padding nor terrain. Classify by
    content instead — a map row is dominated by ocean plus land.
    """
    def is_map(by):
        band = img[by * w:(by + BLOCK) * w]
        counts = collections.Counter(band)
        ocean = counts[0x00]
        land = sum(n for v, n in counts.items() if v >> 4 in (0xB, 0xC, 0xD, 0xE))
        return (ocean + land) / len(band) > 0.75

    # Take the longest *contiguous* run of terrain rows. Spanning min..max
    # would swallow the non-terrain region the historical disk carries above
    # the map, which sits between two separate runs of map-like rows.
    best = run = None
    for by in range(0, h, BLOCK):
        if is_map(by):
            run = (run[0], by) if run else (by, by)
            if best is None or run[1] - run[0] > best[1] - best[0]:
                best = run
        else:
            run = None
    if best is None:
        return img, w, h, 0
    top, bottom = best[0], best[1] + BLOCK
    return img[top * w:bottom * w], w, bottom - top, top


def roll_columns(img, w, h, blocks=1):
    """Rotate the map horizontally by whole blocks.

    The sector stream starts one block before the map's true left edge, so the
    assembled image comes out shifted right — the eastern edge of South America
    wraps around to the left. Chosen objectively rather than by eye: at a
    1-block roll the wrap seam cuts through zero land tiles and column 0 is
    entirely ocean, while every other offset slices a continent in half.
    """
    dx = (blocks * BLOCK) % w
    if not dx:
        return img
    out = bytearray(len(img))
    for y in range(h):
        row = img[y * w:(y + 1) * w]
        out[y * w:(y + 1) * w] = row[dx:] + row[:dx]
    return bytes(out)


def expand_nibbles(img, w, h):
    """Split each byte into its two tiles, high nibble first."""
    width = w * 2
    out = bytearray(width * h)
    for y in range(h):
        row = img[y * w:(y + 1) * w]
        o = y * width
        for x, byte in enumerate(row):
            out[o + x * 2] = byte >> 4
            out[o + x * 2 + 1] = byte & 0x0F
    return bytes(out), width


def render(path, dest, scale=2, first_track=13, roll=1):
    secs = sectors(path, first_track)
    img, w, h = deblock(secs)
    img, w, h, top = crop_to_map(img, w, h)
    img = roll_columns(img, w, h, roll)
    img, w = expand_nibbles(img, w, h)

    counts = collections.Counter(img)
    unknown = {v: n for v, n in counts.items() if v not in NIBBLE}
    flat = []
    for i in range(256):
        flat.extend(NIBBLE.get(i, UNKNOWN))
    im = Image.frombytes("P", (w, h), img)
    im.putpalette(flat)
    im.convert("RGB").resize((w * scale, h * scale), Image.NEAREST).save(dest)

    print(f"{os.path.basename(path)}: {len(secs)} sectors -> {w}x{h} tiles "
          f"(cropped from byte-row {top}) -> {dest}")
    known = sum(n for v, n in counts.items() if v in NIBBLE)
    print(f"  palette covers {100 * known / sum(counts.values()):.1f}% of tiles")
    if unknown:
        top5 = sorted(unknown.items(), key=lambda kv: -kv[1])[:5]
        print("  unmapped nibbles: " +
              ", ".join(f"${v:X}x{n}" for v, n in top5))


if __name__ == "__main__":
    src = sys.argv[1]
    dest = sys.argv[2] if len(sys.argv) > 2 else "map.png"
    render(src, dest)
