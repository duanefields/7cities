#!/usr/bin/env python3
"""Every band write the whole pipeline makes, tagged with the phase that made it.

`range_trace.py` did this for `$2E32`'s ranges and it is what made a
1,750-address phase portable in pieces. Everything left in the World Maker is
bigger and more tangled than that: `$380D`, `$3961` and `$3EAD` are three
entries into one river engine and share 776 addresses between them, so a port
arrives at parts of all three at once and needs to be graded that way.

Same method, wider net. Every write goes through `$0FD3`; at that point
`$29/$2A` is the row and `Y * 2 + X` the column, X being the parity `$0FC3` left
behind. Each write is tagged with the phase `$0E20` is inside and, within the
river phases, with the river — `$32CC` and `$3661` start one.

Also records what the engine puts in high RAM, which is not on the band at all:
`$E000` holds each river's steps three bytes at a time, and `$E2F1` holds the
river mouths. Their contents are map data and stay in `local/`; the fixture gets
counts and digests.
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
BAND_BYTES = 208 * 128
WRITE = 0x0FD3
PIPELINE = 0x0E20

# `$0E20` calls these in order. `$2D23` appears twice with three bytes inside it
# patched differently each time, so the phase is identified by position in the
# sequence rather than by address alone.
PHASES = [(0x2AE9, "islands"), (0x2D23, "spread"), (0x2E32, "terrain"),
          (0x3961, "lakes"), (0x3EAD, "rivers"), (0x2D23, "unspread"),
          (0x47DF, "villages"), (0x4CF2, "4CF2"), (0x2C14, "write")]
ENTRIES = {address for address, _ in PHASES}

# Inside the phases: `$380D` is the river the mountains source, and `$32CC` and
# `$3661` are the two ways a river walk is started.
MARKS = {0x380D: "sources", 0x32CC: "river", 0x3661: "river2"}

# The engine's own record of what it drew, in high RAM.
STEPS, STEPS_BYTES = 0xE000, 0xFB * 3
MOUTHS, MOUTHS_BYTES = 0xE2F1, 0xFB * 3


def digest(items):
    """The same text `range_trace.py` hashes, so the two agree."""
    return hashlib.sha256(
        "\n".join(f"{a},{b},{c}" for a, b, c in items).encode()).hexdigest()


def table_digest(data):
    """High-RAM tables are flat bytes rather than triples."""
    return hashlib.sha256(bytes(data)).hexdigest()


def capture(seed, config, budget):
    cpu = machine(seed, config)
    cpu.run_until({PHASE_DONE}, max_steps=40_000_000)
    cpu.step()
    VirtualDrive().attach(cpu)
    inner = cpu.trace

    bands = []
    live = {"phase": None, "mark": None, "writes": None, "index": 0}

    def start_band():
        bands.append({"phases": [], "rivers": 0})

    def hook(pc, op):
        if pc == PIPELINE:
            start_band()
            live["index"] = 0
            live["phase"] = None
        elif pc in ENTRIES and bands:
            index = live["index"]
            if index < len(PHASES) and PHASES[index][0] == pc:
                live["index"] = index + 1
                live["mark"] = None
                live["writes"] = []
                live["phase"] = PHASES[index][1]
                bands[-1]["phases"].append({
                    "phase": live["phase"],
                    "rng": cpu.rd(0xCD) << 8 | cpu.rd(0xCF),
                    "sha256": hashlib.sha256(
                        bytes(cpu.mem[BASE:BASE + BAND_BYTES])).hexdigest(),
                    "writes": live["writes"]})
        elif pc in MARKS and live["writes"] is not None:
            live["mark"] = MARKS[pc]
            if pc != 0x380D:
                bands[-1]["rivers"] += 1
                live["mark"] = f"river{bands[-1]['rivers']}"
        elif pc == WRITE and live["writes"] is not None:
            row = ((cpu.rd(0x2A) << 8 | cpu.rd(0x29)) - BASE) // 128
            live["writes"].append((cpu.y * 2 + cpu.x, row, cpu.a,
                                   live["mark"] or live["phase"]))
        inner(pc, op)

    cpu.trace = hook
    finished = False
    try:
        cpu.run_until({DONE}, max_steps=budget)
        finished = True
    except BaseException:                                   # noqa: BLE001
        pass
    tables = {"steps": list(cpu.mem[STEPS:STEPS + STEPS_BYTES]),
              "mouths": list(cpu.mem[MOUTHS:MOUTHS + MOUTHS_BYTES])}
    return bands, tables, finished


def summarize(bands):
    out = []
    for band in bands:
        phases = []
        for entry in band["phases"]:
            writes = entry["writes"]
            marks, nibbles = {}, Counter()
            for _, _, value, mark in writes:
                marks[mark] = marks.get(mark, 0) + 1
                nibbles[value] += 1
            parts = []
            for mark in dict.fromkeys(m for *_, m in writes):
                part = [w for w in writes if w[3] == mark]
                parts.append({"mark": mark, "writes": len(part),
                              "sha256": digest((w[0], w[1], w[2]) for w in part)})
            phases.append({"phase": entry["phase"], "rng": entry["rng"],
                           "sha256": entry["sha256"], "writes": len(writes),
                           "nibbles": {f"{k:X}": v for k, v in sorted(nibbles.items())},
                           "marks": parts})
        out.append({"phases": phases})
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", default="0x1234")
    parser.add_argument("--config", type=int, default=0)
    parser.add_argument("--budget", type=int, default=600_000_000)
    args = parser.parse_args()

    seed = int(args.seed, 0)
    bands, tables, finished = capture(seed, args.config, args.budget)
    summary = summarize(bands)
    print(f"seed ${seed:04X} config {args.config}: "
          f"{'finished' if finished else 'BUDGET EXHAUSTED'}")
    for i, band in enumerate(summary):
        print(f"  band {i}:")
        for entry in band["phases"]:
            marks = ", ".join(f"{m['mark']} {m['writes']}" for m in entry["marks"])
            print(f"    {entry['phase']:9s} {entry['writes']:6d} writes"
                  f"  [{marks}]")
    for name, data in tables.items():
        used = len([b for b in data if b])
        print(f"  {name}: {used} non-zero of {len(data)} bytes, "
              f"{table_digest(data)[:8]}")

    path = f"{FIX}/pipeline_reference.json"
    runs = []
    if os.path.exists(path):
        runs = [r for r in json.load(open(path))["runs"]
                if (r["seed"], r["config"]) != (seed, args.config)]
    runs.append({"seed": seed, "config": args.config, "bands": summary,
                 "tables": {name: {"bytes": len(data),
                                   "sha256": table_digest(data)}
                            for name, data in tables.items()}})
    runs.sort(key=lambda r: (r["seed"], r["config"]))
    with open(path, "w") as handle:
        json.dump({"description": "Every band write the World Maker's pipeline "
                                  "makes, per band and per phase: how many, the "
                                  "SHA-256 of the sequence, and the band digest "
                                  "and generator state each phase started from. "
                                  "No map data.",
                   "runs": runs}, handle, indent=1)
    print(f"wrote {os.path.relpath(path, ROOT)}")

    local = f"{ROOT}/local/pipeline_trace_{args.config}.json"
    with open(local, "w") as handle:
        json.dump({"bands": [[{"phase": e["phase"], "writes": e["writes"]}
                              for e in b["phases"]] for b in bands],
                   "tables": tables}, handle)
    print(f"wrote {os.path.relpath(local, ROOT)} "
          f"({os.path.getsize(local):,} bytes) — not for committing")


if __name__ == "__main__":
    main()
