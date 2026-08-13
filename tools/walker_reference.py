#!/usr/bin/env python3
"""Capture one landmass fill as a unit test for the walker port.

Records the machine state at `$23D3` entry and every mask write that follows,
for a single fill. That turns "port the walker" into a closed problem: given this
starting state, produce this sequence of cells.

The three fills captured are the ladder from NOTES.md, easiest first:

    satellite  radius 3   ~23 plots, no backtracking at all
    island     radius 10  ~93 plots, 13 backtracks
    continent  radius 70  ~716 plots, 155 backtracks

The satellite exercises the walk, the plot path and the candidate tests with the
undo ring never used, so it isolates everything that can be got right before
backtracking matters.

The whole of zero page is captured rather than a chosen subset. The walker reads
a lot of it — `$0F`-`$13`, `$18`, `$19`, `$1A`, `$21`, `$25`, `$2B`, `$46`, `$50`,
`$B0`-`$B3` at least — and picking fields in advance risks discovering a
dependency only after the port disagrees. 256 bytes is cheap.

Writes are recorded as offsets from the landmass centre, matching how the
original works: `$22`/`$23:$24` hold the centre and never move during a fill,
while `$14`/`$15` are what the walk advances.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, TABLE_STAGE_DONE  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"

FILL = 0x23D3
PLOT = 0x1728
ERASE = 0x1B3B
BACKTRACK = 0x16D1
BASE = 0x5700

# (seed, config, fill index, label, event cap) — see the ladder above.
#
# The continent is truncated. A port diverges at its *first* wrong cell, so the
# tail adds bytes without adding diagnostic power; 150 events still covers about
# 30 backtracks, which is the part worth exercising. The two small fills are kept
# whole because they are cheap and they terminate naturally.
CASES = [(0x1234, 0, 1, "satellite", None), (0x1234, 0, 4, "island", None),
         (0x1234, 0, 0, "continent", 150)]


def capture(seed, config, index):
    cpu = machine(seed, config)
    state = {}
    events = []
    seen = [0]
    done = [False]

    def hook(pc, op):
        if done[0]:
            return
        if pc == FILL:
            seen[0] += 1
            if seen[0] == index + 1:
                state["zeroPage"] = list(cpu.mem[0x00:0x100])
                state["x"] = cpu.rd(0x22)
                state["y"] = cpu.rd(0x23) | cpu.rd(0x24) << 8
                state["radius"] = cpu.rd(0xB0)
            elif seen[0] == index + 2:
                done[0] = True
            return
        if seen[0] != index + 1:
            return
        if pc in (PLOT, ERASE, BACKTRACK):
            kind = {PLOT: "plot", ERASE: "erase", BACKTRACK: "backtrack"}[pc]
            events.append({"kind": kind, "dx": cpu.rd(0x14), "dy": cpu.rd(0x15),
                           "heading": cpu.rd(0x1A), "step": cpu.rd(0x46),
                           "workingRadius": cpu.rd(0x21)})

    cpu.trace = hook
    cpu.run_until({TABLE_STAGE_DONE})
    return state, events


def main():
    out = {"description": "One land-mass fill from the original 6502, captured "
                          "in the interpreter. Machine state at $23D3 entry and "
                          "every mask write that follows, as offsets from the "
                          "landmass centre. No map data.",
           "cases": []}
    for seed, config, index, label, cap in CASES:
        state, events = capture(seed, config, index)
        total = len(events)
        if cap is not None and total > cap:
            events = events[:cap]
        if not state:
            print(f"  {label}: fill {index} not reached", flush=True)
            continue
        plots = sum(1 for e in events if e["kind"] == "plot")
        erases = sum(1 for e in events if e["kind"] == "erase")
        backs = sum(1 for e in events if e["kind"] == "backtrack")
        out["cases"].append({"label": label, "seed": seed, "config": config,
                             "fillIndex": index, **state,
                             "eventsTotal": total, "eventsRecorded": len(events),
                             "truncated": len(events) < total,
                             "events": events})
        print(f"  {label:<10} centre=({state['x']},{state['y']}) r={state['radius']}"
              f"  {plots} plots, {erases} erases, {backs} backtracks", flush=True)

    path = f"{FIX}/walker_reference.json"
    with open(path, "w") as f:
        json.dump(out, f, indent=1)
    size = os.path.getsize(path)
    print(f"\nwrote {len(out['cases'])} cases -> {os.path.relpath(path, ROOT)} "
          f"({size:,} bytes)")


if __name__ == "__main__":
    main()
