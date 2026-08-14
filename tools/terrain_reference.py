#!/usr/bin/env python3
"""Capture the terrain pipeline phase by phase, for a port to be graded against.

The map is built a band at a time — 208 rows of nibbles at `$5700`, two bands to
cover 400 rows, overlapping by sixteen. `$0E20` runs the pipeline once per band,
and this records the band at every phase boundary: what went in, what came out,
and how many of each nibble there were.

Digests rather than cells, for the usual reason — a band is 26,624 bytes of
generated map. The nibble histogram goes in as well, because it is small and it
is what makes a failure legible: a port that gets the count of forest right and
its placement wrong fails differently from one that never writes forest at all.

Needs `vdrive.py`, since none of this runs without a disk.
"""
import argparse
import hashlib
import json
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, PHASE_DONE  # noqa: E402
from vdrive import VirtualDrive  # noqa: E402
from wm_disk import DONE  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"

BASE = 0x5700
BAND_ROWS = 208
BAND_BYTES = BAND_ROWS * 128

# The pipeline at `$0E20`, in the order it calls them. `$2D23` appears twice with
# three bytes inside it patched differently each time.
PIPELINE = 0x0E20
# `$2A45` clamps a bounding box around a point: x to 0...255 and y to 0...207,
# the band's own height. Small, pure, and used by everything downstream, so it is
# the first thing worth grading a port on.
BOX = 0x2A45
BOX_DONE = 0x2A77
BOX_CASES = 200
# `$2B8A`, the one write in `$2AE9`'s island marking: every plain cell in a
# radius-10 box around a second-wave island becomes nibble `$3`. Recording the
# cells rather than the band isolates the marking from `$28F1`, which has already
# been over the same band and changed it.
MARK = 0x2B8A
# `$2ED2` is where `$2E32` starts reading the landmass position tables, so it is
# the moment to record them: `$1B5F` has filed them and `$1D42` has fixed them up.
TABLES = 0x2ED2
# `$28F1` is the first thing `$2AE9` does and the first that touches the band, so
# it gets its own boundary.
PHASES = [(0x2AE9, "islands"), (0x2B42, "afterScatter"), (0x2D23, "spread"), (0x2E32, "terrain"),
          (0x3961, "3961"), (0x3EAD, "rivers"), (0x2D23, "unspread"),
          (0x47DF, "villages"), (0x4CF2, "4CF2"), (0x2C14, "write")]
ENTRIES = {address for address, _ in PHASES}
# Inside `$2E32`, which is the largest phase and too big to port in one go. Its
# three band sweeps run back to back with no observable boundary between them, so
# without these a first attempt can only be graded on the phase as a whole — which
# says nothing about *which* sweep is wrong. `$2F04` is the head of the per-
# landmass range loop, and records the entry it is about to draw.
SWEEPS = {0x2E5B: "sweep1", 0x2E84: "sweep2", 0x2ED2: "sweep3"}
RANGE = 0x2F04
# `$2B42` is inside `$2AE9`, so it must not reset the step list the way `$0E20`
# does; the index bookkeeping below already handles that.


def capture(seed, config, budget):
    cpu = machine(seed, config)
    cpu.run_until({PHASE_DONE}, max_steps=40_000_000)
    cpu.step()
    drive = VirtualDrive()
    drive.attach(cpu)
    inner = cpu.trace

    bands = []
    live = {"steps": []}
    boxes, box_seen, box_pending = [], set(), []
    marks = [[]]
    tables = []
    sweeps = []

    def snapshot():
        band = bytes(cpu.mem[BASE:BASE + BAND_BYTES])
        counts = Counter()
        for byte in band:
            counts[byte >> 4] += 1
            counts[byte & 15] += 1
        return {"sha256": hashlib.sha256(band).hexdigest(),
                # The generator carries straight through from the land-mass phase
                # and the band writer, so a port cannot derive it — a phase can
                # only be graded from the state it actually started with.
                "rng": cpu.rd(0xCD) << 8 | cpu.rd(0xCF),
                "band": cpu.rd(0x10),
                "nibbles": {f"{k:X}": counts[k] for k in sorted(counts) if counts[k]}}

    def hook(pc, op):
        if pc == BOX and len(boxes) < BOX_CASES:
            box_pending.append((cpu.a, cpu.rd(0x22), cpu.rd(0x23)))
        elif pc == BOX_DONE and box_pending:
            radius, x, y = box_pending.pop()
            if (radius, x, y) not in box_seen:
                box_seen.add((radius, x, y))
                boxes.append({"radius": radius, "x": x, "y": y,
                              "left": cpu.rd(0x03), "right": cpu.rd(0x04),
                              "top": cpu.rd(0x05), "bottom": cpu.rd(0x06)})
        if pc == TABLES and not tables:
            for base, count in ((0x0300, cpu.rd(0x63)), (0x033C, cpu.rd(0x64))):
                tables.append([[cpu.rd(base + i * 3 + 1), cpu.rd(base + i * 3),
                                cpu.rd(base + i * 3 + 2)] for i in range(count)])
        if pc == MARK:
            marks[-1].append((cpu.rd(0x27), cpu.rd(0x05)))
        if pc in SWEEPS and sweeps:
            sweeps[-1].append({"phase": SWEEPS[pc], **snapshot()})
        elif pc == RANGE and sweeps:
            sweeps[-1].append({"phase": "range", "radius": cpu.rd(0x21),
                               "x": cpu.rd(0x22), "y": cpu.rd(0x23), **snapshot()})
        if pc == PIPELINE:
            if marks[-1]:
                marks.append([])
            live["steps"] = []
            bands.append(live["steps"])
            sweeps.append([])
        elif pc in ENTRIES and bands:
            # Which phase this is depends on how many have run for this band,
            # because `$2D23` is two different steps.
            index = len(live["steps"])
            if index < len(PHASES) and PHASES[index][0] == pc:
                live["steps"].append({"phase": PHASES[index][1], **snapshot()})
        inner(pc, op)

    cpu.trace = hook
    finished = False
    try:
        cpu.run_until({DONE}, max_steps=budget)
        finished = True
    except BaseException:                                   # noqa: BLE001
        pass
    marked = [{"cells": len(cells),
               "sha256": hashlib.sha256(
                   "\n".join(f"{x},{y}" for x, y in cells).encode()).hexdigest()}
              for cells in marks if cells]
    return bands, boxes, marked, tables, sweeps, finished


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", default="0x1234")
    parser.add_argument("--config", type=int, default=0)
    parser.add_argument("--budget", type=int, default=600_000_000)
    args = parser.parse_args()

    seed = int(args.seed, 0)
    bands, boxes, marked, tables, sweeps, finished = capture(seed, args.config, args.budget)
    print(f"seed ${seed:04X} config {args.config}: {len(bands)} bands, "
          f"{'finished' if finished else 'BUDGET EXHAUSTED'}", flush=True)
    print(f"  {len(boxes)} distinct bounding boxes")
    print(f"  island marks per band: {[m['cells'] for m in marked]}")
    print(f"  landmass tables: {tables}")
    for i, steps in enumerate(bands):
        print(f"  band {i}: " + ", ".join(
            f"{s['phase']} {s['sha256'][:8]}" for s in steps))
    for i, steps in enumerate(sweeps):
        print(f"  band {i} inside $2E32: {len(steps)} checkpoints, " + ", ".join(
            f"{s['phase']} {s['sha256'][:8]}" for s in steps[:4]) + " ...")

    out = {"description": "The terrain pipeline at $0E20, one entry per phase "
                          "per band. Digests and nibble histograms of the "
                          "26,624-byte band at $5700. No map data.",
           "seed": seed, "config": args.config,
           "bandRows": BAND_ROWS, "bands": bands, "boundingBoxes": boxes,
           "islandMarks": marked, "terrainSweeps": sweeps,
           "landmassTables": {"northern": tables[0] if tables else [],
                              "southern": tables[1] if len(tables) > 1 else []}}
    path = f"{FIX}/terrain_reference.json"
    with open(path, "w") as handle:
        json.dump(out, handle, indent=1)
    print(f"wrote {os.path.relpath(path, ROOT)} "
          f"({os.path.getsize(path):,} bytes)")


if __name__ == "__main__":
    main()
