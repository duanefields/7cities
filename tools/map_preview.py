#!/usr/bin/env python3
"""Render a Seven Cities of Gold map disk to a PNG.

The map is stored *blocked*, not row-major. The World Maker's sector-write
loop at $0F54 gathers 16 bytes from each of 16 source rows spaced $80 apart,
so every 256-byte sector is a 16x16 tile block. Blocks tile left-to-right,
16 per row, giving a 256-tile-wide map.

Getting this wrong is why row-major renderings smeared land into horizontal
streaks and why no stride search ever found a peak.
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

# Terrain palette.
#
# Confirmed: $00 is ocean and $BB is land — those are what the land-mass phase
# writes, verified by diffing a disk before and after that phase.
#
# The rest is structural inference, not yet confirmed against the terrain
# phase: values group by HIGH NIBBLE ($Bx, $Cx, $Dx, $Ex), which reads as a
# terrain class with the low nibble carrying a variant. Colored as a plausible
# elevation ramp so the map is legible; treat the specific assignments as
# provisional.
PALETTE = {
    0x00: (12, 34, 102),      # ocean (confirmed)
    0x01: (198, 178, 120),    # padding outside the map
    0x4B: (90, 90, 120),      # per-sector marker
    0x0B: (64, 164, 223),     # ? shallows / river
    0x11: (32, 62, 138),      # ? deeper or secondary water
    0x80: (120, 170, 90),     # ? grassland
}
# High-nibble terrain classes, low nibble = variant.
NIBBLE_RAMP = {
    0xB: (74, 150, 64),       # land / plain (confirmed for $BB)
    0xC: (150, 160, 70),      # ? scrub / hills
    0xD: (140, 120, 80),      # ? highland
    0xE: (130, 130, 135),     # ? mountain
    0xF: (235, 235, 240),     # ? peak / marker
}
UNKNOWN = (230, 60, 200)      # loud magenta: still unmapped


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


def render(path, dest, scale=3, first_track=13):
    secs = sectors(path, first_track)
    img, w, h = deblock(secs)
    img, w, h, top = crop_to_map(img, w, h)

    counts = collections.Counter(img)

    def color(v):
        if v in PALETTE:
            return PALETTE[v]
        base = NIBBLE_RAMP.get(v >> 4)
        if base is None:
            return None
        # low nibble shades the class slightly, so variants stay visible
        k = (v & 0x0F) - 8
        return tuple(max(0, min(255, c + k * 5)) for c in base)

    unknown = {v: n for v, n in counts.items() if color(v) is None}

    flat = []
    for i in range(256):
        flat.extend(color(i) or UNKNOWN)
    im = Image.frombytes("P", (w, h), img)
    im.putpalette(flat)
    im.convert("RGB").resize((w * scale, h * scale), Image.NEAREST).save(dest)

    print(f"{os.path.basename(path)}: {len(secs)} sectors -> {w}x{h} tiles "
          f"(cropped from row {top}) -> {dest}")
    known = sum(n for v, n in counts.items() if v not in unknown)
    print(f"  palette covers {100 * known / sum(counts.values()):.1f}% of cells")
    if unknown:
        top5 = sorted(unknown.items(), key=lambda kv: -kv[1])[:5]
        print("  unmapped values: " +
              ", ".join(f"${v:02X}x{n}" for v, n in top5))


if __name__ == "__main__":
    src = sys.argv[1]
    dest = sys.argv[2] if len(sys.argv) > 2 else "map.png"
    render(src, dest)
