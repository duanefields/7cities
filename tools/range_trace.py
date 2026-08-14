#!/usr/bin/env python3
"""Every band write the range half of `$2E32` makes, in order, per landmass.

The three sweeps at the head of `$2E32` can be graded on a band digest, because
there are only three of them and the fixture records a checkpoint between each.
The ranges cannot: they run one after another over a band a port has no way to
reconstruct, since the first landmass in a band is drawn by the walker at
`$2F8C` and the second by `$2F0B`, and a port that has only one of the two
cannot start the other from the right state.

So grade on the *writes* instead. Every cell the range drawers put down goes
through `$0FD3`, and at that point the pointer and the index registers say
exactly where: `$29/$2A` is the row and `Y * 2 + X` the column, X being the
parity `$0FC3` left behind. A port that produces the same sequence is right, and
one that diverges says on which write.

Writes the full sequence to `local/` for diffing and prints a digest per
landmass, which is what belongs in a fixture — a list of 1,159 mountain cells is
map data, its SHA-256 is not.
"""
import argparse
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, PHASE_DONE  # noqa: E402
from vdrive import VirtualDrive  # noqa: E402
from wm_disk import DONE  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

BASE = 0x5700
WRITE = 0x0FD3
PIPELINE = 0x0E20
TERRAIN = 0x2E32
RANGES = 0x2ED2
ENTRY = 0x2F04          # the landmass loop, with $21/$22/$23 loaded
DONE_RANGES = 0x3961    # the phase after $2E32
# `$0B16` is the scattered draw the walkers steer by, and the first thing in the
# pipeline to use it. Twelve register advances a call, so getting it wrong
# desynchronizes everything after it — worth its own fixture rather than being
# inferred from a band that disagrees.
SCATTER, SCATTER_DONE = 0x0B16, 0x0B82
SCATTER_CASES = 400
# `$2E32` draws a landmass in stages, and a port arrives at them one at a time.
# Tagging each write with the stage that made it means a port of `$2F8C` alone
# can be graded on `$2F8C`'s writes instead of having to match the whole entry.
STAGES = {0x2F0B: "arms", 0x2F8C: "spine", 0x3134: "spur",
          0x31E6: "clearing", 0x380D: "sources"}


def capture(seed, config, budget):
    cpu = machine(seed, config)
    cpu.run_until({PHASE_DONE}, max_steps=40_000_000)
    cpu.step()
    VirtualDrive().attach(cpu)
    inner = cpu.trace

    bands = []
    live = {"drawing": False, "stage": "?", "writes": None}
    scatter, pending = [], []

    def hook(pc, op):
        if pc == SCATTER and len(scatter) < SCATTER_CASES:
            pending.append((cpu.a, cpu.y, cpu.rd(0xCD) << 8 | cpu.rd(0xCF)))
        elif pc == SCATTER_DONE and pending:
            mean, spread, before = pending.pop()
            scatter.append({"mean": mean, "spread": spread, "rng": before,
                            "value": cpu.a,
                            "after": cpu.rd(0xCD) << 8 | cpu.rd(0xCF)})
        if pc == PIPELINE:
            bands.append([])
            live["drawing"] = False
        elif pc == RANGES:
            live["drawing"] = True
        elif pc == DONE_RANGES:
            live["drawing"] = False
        elif pc == ENTRY and bands:
            live["writes"] = []
            live["stage"] = "?"
            bands[-1].append({"radius": cpu.rd(0x21), "x": cpu.rd(0x22),
                              "y": cpu.rd(0x23), "writes": live["writes"]})
        elif pc in STAGES:
            live["stage"] = STAGES[pc]
        elif pc == WRITE and live["drawing"] and live["writes"] is not None:
            row = ((cpu.rd(0x2A) << 8 | cpu.rd(0x29)) - BASE) // 128
            live["writes"].append((cpu.y * 2 + cpu.x, row, cpu.a,
                                   live["stage"]))
        inner(pc, op)

    cpu.trace = hook
    try:
        cpu.run_until({DONE}, max_steps=budget)
    except BaseException:                                   # noqa: BLE001
        pass
    return bands, scatter


def digest(writes):
    return hashlib.sha256(
        "\n".join(f"{x},{y},{v}" for x, y, v, _ in writes).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", default="0x1234")
    parser.add_argument("--config", type=int, default=0)
    parser.add_argument("--budget", type=int, default=600_000_000)
    args = parser.parse_args()

    bands, scatter = capture(int(args.seed, 0), args.config, args.budget)
    out = []
    for i, ranges in enumerate(bands):
        summary = []
        for entry in ranges:
            writes = entry["writes"]
            stages = []
            for stage in STAGES.values():
                part = [w for w in writes if w[3] == stage]
                if part:
                    stages.append({"stage": stage, "writes": len(part),
                                   "sha256": digest(part)})
            summary.append({"radius": entry["radius"], "x": entry["x"],
                            "y": entry["y"], "writes": len(writes),
                            "stages": stages, "sha256": digest(writes)})
            print(f"  band {i} radius {entry['radius']:3d} at "
                  f"({entry['x']:3d},{entry['y']:3d}): {len(writes):5d} writes "
                  + ", ".join(f"{s['stage']} {s['writes']}/{s['sha256'][:8]}"
                              for s in stages))
        out.append(summary)

    fixture = (f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"
               "/scatter_reference.json")
    with open(fixture, "w") as handle:
        json.dump({"description": "$0B16, the scattered draw, as the World Maker "
                                  "called it: mean, spread, the generator before "
                                  "and after, and the value. No map data.",
                   "draws": scatter}, handle, indent=1)
    print(f"wrote {os.path.relpath(fixture, ROOT)}: {len(scatter)} draws")

    stage_path = (f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"
                  "/range_reference.json")
    with open(stage_path, "w") as handle:
        json.dump({"description": "The writes $2E32's range half makes, per "
                                  "landmass and per stage: how many, and the "
                                  "SHA-256 of the sequence. No map data.",
                   "bands": out}, handle, indent=1)
    print(f"wrote {os.path.relpath(stage_path, ROOT)}")

    path = f"{ROOT}/local/range_trace.json"
    with open(path, "w") as handle:
        json.dump([[{**e, "writes": e["writes"]} for e in b] for b in bands],
                  handle)
    print(f"wrote {os.path.relpath(path, ROOT)} "
          f"({os.path.getsize(path):,} bytes) — not for committing")
    return out


if __name__ == "__main__":
    main()
