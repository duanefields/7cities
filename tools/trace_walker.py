#!/usr/bin/env python3
"""Trace one landmass fill, so the walker can be ported against a reference.

The walker is a backtracking search: it plots, decides a step is unworkable,
unwinds, and tries again. Reading the disassembly gives its parts; this gives its
*behaviour* — how often it backtracks, how deep, how many cells it draws and
erases, and what the state looks like at each decision.

That is the reference a Swift transcription gets diffed against. Without it, a
port can only be compared on the finished mask, where every possible bug looks
identical.

Watched addresses, all established in NOTES.md:

    $23D3  fill entry, once per accepted landmass
    $15AD  the walker's main loop
    $1728  plot   — the only routine that sets a mask bit
    $1B3B  erase  — clears one, during an unwind
    $16D1  backtrack — pops a record off the ring at $9100
    $1900  the bounds guard whose failure branch restarts generation
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, TABLE_STAGE_DONE  # noqa: E402

FILL = 0x23D3
WALK = 0x15AD
PLOT = 0x1728
ERASE = 0x1B3B
BACKTRACK = 0x16D1
GUARD = 0x1900
WATCH = {FILL: "fill", WALK: "walk", PLOT: "plot", ERASE: "erase",
         BACKTRACK: "backtrack", GUARD: "guard"}

# Walker state, from NOTES.md.
STATE = {"x": 0x22, "yLo": 0x23, "yHi": 0x24, "heading": 0x1A,
         "step": 0x46, "dx": 0x14, "dy": 0x15, "r": 0x21, "R": 0xB0}


def trace(seed, config, landmass=0, limit=400):
    cpu = machine(seed, config)
    counts = collections.Counter()
    events = []
    fills = [0]

    def hook(pc, op):
        if pc not in WATCH:
            return
        kind = WATCH[pc]
        if kind == "fill":
            fills[0] += 1
        if fills[0] != landmass + 1:
            return
        counts[kind] += 1
        if len(events) < limit and kind in ("plot", "erase", "backtrack", "fill"):
            s = {k: cpu.rd(a) for k, a in STATE.items()}
            s["y"] = s.pop("yLo") | s.pop("yHi") << 8
            events.append((kind, s))

    cpu.trace = hook
    cpu.run_until({TABLE_STAGE_DONE})
    return counts, events, fills[0]


def main():
    seed = int(sys.argv[1], 0) if len(sys.argv) > 1 else 0x1234
    config = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    which = int(sys.argv[3]) if len(sys.argv) > 3 else 0

    counts, events, fills = trace(seed, config, which)
    print(f"seed ${seed:04X} config {config}, landmass {which} of {fills}\n")
    print("  activity:")
    for kind in ("walk", "plot", "erase", "backtrack", "guard"):
        print(f"    {kind:<10} {counts[kind]:>8,}")
    drawn = counts["plot"] - counts["erase"]
    if counts["plot"]:
        print(f"    {'net cells':<10} {drawn:>8,} "
              f"({counts['erase'] * 100 / counts['plot']:.1f}% of plots erased)")

    print(f"\n  first {min(len(events), 24)} events:")
    print(f"    {'event':<10} {'x':>4} {'y':>4} {'hd':>3} {'step':>5} "
          f"{'dx':>4} {'dy':>4} {'r':>4} {'R':>4}")
    for kind, s in events[:24]:
        print(f"    {kind:<10} {s['x']:>4} {s['y']:>4} {s['heading']:>3} "
              f"{s['step']:>5} {s['dx']:>4} {s['dy']:>4} {s['r']:>4} {s['R']:>4}")


if __name__ == "__main__":
    main()
