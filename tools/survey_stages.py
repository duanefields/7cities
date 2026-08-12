#!/usr/bin/env python3
"""Find the code stages on a disk image and work out where each one loads.

The loader stores raw sectors page-aligned (see NOTES.md), so a stage is just a
contiguous run in loader order. Nothing on the disk says where a run loads, but
the code says it itself: a correct load address makes internal `JSR`/`JMP`
targets land on instruction starts, and a wrong one scatters them. Scoring that
across candidate base addresses recovers the address.

    tools/survey_stages.py d64/7CITIES1.D64
    tools/survey_stages.py d64/7CITIES1.D64 --extract 11 17 -o local/stage_t11.bin
"""
import argparse

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_stage import extract, SECTORS_PER_TRACK, SECTORS_READ  # noqa: E402

# Opcodes common enough that landing on one is weak evidence of an instruction
# boundary, and rare enough in data that the signal survives.
COMMON = {0xA9, 0xA2, 0xA0, 0x85, 0x86, 0x84, 0x8D, 0x8E, 0x8C, 0x20, 0x60,
          0x4C, 0xAD, 0xAE, 0xAC, 0xA5, 0xA6, 0xA4, 0x18, 0x38, 0x48, 0x68,
          0xE8, 0xC8, 0xCA, 0x88, 0x29, 0x09, 0x49, 0x69, 0xE9, 0xC9, 0xD0,
          0xF0, 0x90, 0xB0, 0x78, 0x58, 0xB9, 0xBD, 0x99, 0x9D, 0x91, 0xB1}


def track_start(track):
    """Index into loader order of the first sector of `track`."""
    n = 0
    for t in range(1, track):
        n += min(SECTORS_READ, SECTORS_PER_TRACK[t - 1])
    return n


def track_span(lo, hi):
    start = track_start(lo)
    return start, track_start(hi + 1) - start


def score_base(data, base):
    """Fraction of in-range JSR/JMP targets landing on a common opcode."""
    good = total = 0
    for i in range(len(data) - 2):
        if data[i] in (0x20, 0x4C):
            t = (data[i + 1] | data[i + 2] << 8) - base
            if 0 <= t < len(data):
                total += 1
                good += data[t] in COMMON
    return (good / total if total else 0.0), total


def best_base(data, lo=0x0800, hi=0xC000):
    ranked = []
    for base in range(lo, hi, 0x100):
        frac, n = score_base(data, base)
        if n >= 20:
            ranked.append((frac, n, base))
    ranked.sort(reverse=True)
    return ranked


def code_density(b):
    return b.count(0x20) + b.count(0x60) + b.count(0xA9) + b.count(0x85)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("image")
    p.add_argument("--extract", nargs=2, type=int, metavar=("LO", "HI"),
                   help="extract tracks LO..HI instead of surveying")
    p.add_argument("-o", "--out")
    a = p.parse_args()
    img = open(a.image, "rb").read()

    if a.extract:
        lo, hi = a.extract
        skip, n = track_span(lo, hi)
        data = extract(img, skip, n)
        ranked = best_base(data)
        print(f"tracks {lo}-{hi}: {n} sectors, {len(data)} bytes")
        for frac, cnt, base in ranked[:5]:
            print(f"    ${base:04X}  {frac * 100:5.1f}%  ({cnt} targets)")
        if a.out:
            open(a.out, "wb").write(data)
            print(f"  wrote {a.out}")
        return

    print(f"{'trk':>4} {'code':>6}  best load addresses")
    for t in range(1, 36):
        skip, n = track_span(t, t)
        data = extract(img, skip, n)
        d = code_density(data)
        if d < 40:
            continue
        ranked = best_base(data)[:3]
        cells = "  ".join(f"${b:04X} {f * 100:.0f}%" for f, _, b in ranked)
        print(f"{t:4d} {d:6d}  {cells}")


if __name__ == "__main__":
    main()
