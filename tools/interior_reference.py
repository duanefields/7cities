#!/usr/bin/env python3
"""Capture the land-mass stage as an ordered list of the things that touch the mask.

`walker_reference.py` grades the coastline walker one fill at a time from a
recorded starting state. This is the rung above it: every walk, every flood fill
and every mirror the stage performs, in the order it performs them, each with the
mask digest it started from. Replaying the list from an empty mask and matching
every digest exercises the walker, the interior fill at `$194A`, and the fact
that landmass *n* sees what landmasses 0 to *n-1* left behind.

Recording the *order* is the point, because it is not the order anyone would
guess. Two things make it strange:

**Walks and fills are not paired one to one.** A continent's walk does not fill
its own interior. It reaches `$1666`, finds `$54` clear, patches a command into
`$0200` and arranges a walk for the satellite that goes with it — and that walk,
finding `$54` set, reaches `$168D JMP $194A`. Since the satellite sits inside the
continent's outline, that one flood fills both, seeded from the continent's
centre. Six walks produce four fills.

**A mirror lands in the middle of it.** `$4500 JSR $1C89` flips two coins and, on
each, mirrors the whole 12,800-byte mask — left to right by reversing all 256
bits of every row, top to bottom by swapping row *r* with row 399 - *r*. It runs
after the paired continents and before the islands. Nothing about it goes through
the mask's own write path, so a replay assembled only from traced writes puts
every landmass after it in the wrong place, and the surrounding steps still look
perfect. That is exactly how it was found: the writes all matched, the mask did
not, and the difference was a clean 60-row translation.

So the capture makes no attempt to attribute fills to landmasses. It records
steps:

    outline    $23D3 — centre, radius and zero page, then the walk's writes
    interior   $194A — centre, then the flood's writes
    mirror     $1C89 — which of the two flips fired

Each step carries a digest of its own writes and of the mask it began with, and
a final digest closes the stage. Digests rather than cells throughout: a
continent is ~870 outline writes and ~14,000 interior ones, and committing those
would be committing generated maps.

The placement loop decides where landmasses go and is deliberately *not* under
test here — each step's starting state is recorded so a port can be graded on the
walk and the fill alone. `landmass_reference.json` is what grades placement, end
to end.
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, TABLE_STAGE_DONE, BASE, MASK_BYTES  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"

WALK = 0x23D3
FLOOD = 0x194A
# `$1C89`, reached from `$4500`: two independent coin flips that mirror the whole
# mask left-right and top-bottom. It runs partway through the stage, between the
# paired continents and the islands, so a replay that ignores it has every
# landmass after it in the wrong place.
MIRROR = 0x1C89
MIRROR_DONE = 0x1D3B
PLOT = 0x1728
ERASE = 0x1B3B
RESOLVE = 0x13E0
PLOT_RESOLVED = 0x172B
ERASE_RESOLVED = 0x1B42

# The flood fill's one write, `STA ($29),Y` at `$1987`. It sets the bit directly
# rather than calling `$1728`, which is why the walker fixture shows no trace of
# the interior at all.
INTERIOR_WRITE = 0x1987

SEED, CONFIG = 0x1234, 0

# The replay fixture is one case, because each of its outline steps carries 256
# bytes of zero page. The self-driving port needs no zero page at all — only the
# seed — so it is graded on all nine, with just the step list and the mask digest
# where the port stops.
UNAIDED = [(seed, config) for seed in (0x1234, 0xBEEF, 0x0001)
           for config in (0, 1, 2)]


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def capture(seed, config):
    cpu = machine(seed, config)
    steps = []
    pending = [None]

    def mask_digest():
        return hashlib.sha256(bytes(cpu.mem[BASE:BASE + MASK_BYTES])).hexdigest()

    def row_of(pointer):
        return (pointer - BASE) >> 5

    def hook(pc, op):
        if pc in (WALK, FLOOD):
            step = {"kind": "outline" if pc == WALK else "interior",
                    "x": cpu.rd(0x22), "y": cpu.rd(0x23) | cpu.rd(0x24) << 8,
                    "maskBefore": mask_digest(), "writes": []}
            if pc == WALK:
                step["radius"] = cpu.rd(0xB0)
                step["zeroPage"] = list(cpu.mem[0x00:0x100])
            steps.append(step)
            return
        if pc == MIRROR:
            steps.append({"kind": "mirror", "maskBefore": mask_digest(),
                          "writes": []})
            return
        if pc == MIRROR_DONE and steps and steps[-1]["kind"] == "mirror":
            # `$B7` and `$B8` are the two flips' flags, each `DEC`ed from zero to
            # `$FF` when its coin came up negative.
            steps[-1]["horizontal"] = cpu.rd(0xB7) != 0
            steps[-1]["vertical"] = cpu.rd(0xB8) != 0
            return
        if not steps:
            return
        live = steps[-1]
        if pc in (PLOT, ERASE):
            pending[0] = "P" if pc == PLOT else "E"
        elif pc == RESOLVE and pending[0]:
            live["writes"].append(pending[0])
            pending[0] = None
        elif pc in (PLOT_RESOLVED, ERASE_RESOLVED) and live["writes"]:
            row = row_of(cpu.rd(0x2A) << 8 | cpu.rd(0x29))
            live["writes"][-1] += f" {cpu.y * 8 + cpu.x},{row}"
        elif pc == INTERIOR_WRITE:
            row = row_of(cpu.rd(0x2A) << 8 | cpu.rd(0x29))
            live["writes"].append(f"P {cpu.y * 8 + cpu.x},{row}")

    cpu.trace = hook
    cpu.run_until({TABLE_STAGE_DONE})
    final = {"maskSha256": mask_digest(),
             "landCells": sum(b.bit_count()
                              for b in cpu.mem[BASE:BASE + MASK_BYTES])}
    return steps, final


def main():
    steps, final = capture(SEED, CONFIG)
    out = {"description": "Every walk and every flood fill the command-table "
                          "stage performs, in order, captured in the "
                          "interpreter. Starting state and write digests per "
                          "step, mask digests throughout. No map data.",
           "seed": SEED, "config": CONFIG, "steps": [], **final}
    for i, s in enumerate(steps):
        record = {"index": i, "kind": s["kind"], "maskBefore": s["maskBefore"],
                  "writes": len(s["writes"]),
                  "writesSha256": sha("\n".join(s["writes"]))}
        if s["kind"] == "mirror":
            record["horizontal"] = s["horizontal"]
            record["vertical"] = s["vertical"]
            note = f"horizontal={s['horizontal']} vertical={s['vertical']}"
        else:
            record["x"], record["y"] = s["x"], s["y"]
            note = f"centre=({s['x']},{s['y']})"
            if s["kind"] == "outline":
                record["radius"] = s["radius"]
                record["zeroPage"] = s["zeroPage"]
                note += f" r={s['radius']}"
        out["steps"].append(record)
        print(f"  {i}  {s['kind']:<8} {note:<34}"
              f"{len(s['writes']):>6} writes", flush=True)
    print(f"\n  stage end: {final['landCells']:,} land cells")

    # The compact section: every seed and configuration, truncated where the port
    # has to stop, which is the mirror at the end of the first command.
    out["unaided"] = []
    for seed, config in UNAIDED:
        steps, _ = capture(seed, config)
        cut = next((i for i, s in enumerate(steps) if s["kind"] == "mirror"), None)
        if cut is None or cut + 1 >= len(steps):
            print(f"  seed ${seed:04X} config {config}: no mirror, skipped",
                  flush=True)
            continue
        compact = []
        for s in steps[:cut + 1]:
            entry = {"kind": s["kind"]}
            if s["kind"] == "mirror":
                entry["horizontal"], entry["vertical"] = s["horizontal"], s["vertical"]
            else:
                entry["x"], entry["y"] = s["x"], s["y"]
                if s["kind"] == "outline":
                    entry["radius"] = s["radius"]
            compact.append(entry)
        out["unaided"].append({"seed": seed, "config": config, "steps": compact,
                               "maskSha256": steps[cut + 1]["maskBefore"]})
        print(f"  seed ${seed:04X} config {config}: {len(compact)} steps to the "
              f"mirror", flush=True)

    path = f"{FIX}/interior_reference.json"
    with open(path, "w") as fh:
        json.dump(out, fh, indent=1)
    print(f"wrote {len(out['steps'])} steps -> {os.path.relpath(path, ROOT)} "
          f"({os.path.getsize(path):,} bytes)")


if __name__ == "__main__":
    main()
