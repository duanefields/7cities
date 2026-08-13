#!/usr/bin/env python3
"""Capture the walk's per-step decisions, for porting `$1555` and `$1583`.

These are the only routines in the walk that consume randomness, so they set the
whole sequence. Each records what went in — the LFSR state, the threshold `$18`,
the axis `$19`, the direction bias `$B1`/`$B2`, the heading — and what came out:
the advanced coordinate and the LFSR state afterwards.

The LFSR state matters as much as the coordinate. A stepper that lands on the
right value having consumed a different number of draws desynchronizes
everything after it, and the finished mask is the only place that would show up.

`$1555` steps x and writes `$44`; `$1583` steps y and writes `$45`. Exactly one
runs per iteration, chosen at `$252C` by whichever of `$14`/`$15` is smaller.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, TABLE_STAGE_DONE  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"
FILL, STEP_X, STEP_Y, RET_X, RET_Y = 0x23D3, 0x1555, 0x1583, 0x1582, 0x15AC
CASES = [(0x1234, 0, 1, "satellite", 40), (0x1234, 0, 4, "island", 60),
         (0x1234, 0, 0, "continent", 60)]


def capture(seed, config, index, cap):
    cpu = machine(seed, config)
    seen, done, pending, out = [0], [False], [None], []

    def hook(pc, op):
        if done[0]:
            return
        if pc == FILL:
            seen[0] += 1
            if seen[0] == index + 2:
                done[0] = True
            return
        if seen[0] != index + 1 or len(out) >= cap:
            return
        if pc in (STEP_X, STEP_Y):
            pending[0] = {
                "axis": "x" if pc == STEP_X else "y",
                "rngHigh": cpu.rd(0xCD), "rngLow": cpu.rd(0xCF),
                "threshold": cpu.rd(0x18), "axisSelect": cpu.rd(0x19),
                "biasX": cpu.rd(0xB1), "biasY": cpu.rd(0xB2),
                "heading": cpu.rd(0x1A),
                "inX": cpu.rd(0x44), "inY": cpu.rd(0x45),
            }
        elif pc in (RET_X, RET_Y) and pending[0]:
            pending[0].update(outX=cpu.rd(0x44), outY=cpu.rd(0x45),
                              rngHighAfter=cpu.rd(0xCD), rngLowAfter=cpu.rd(0xCF))
            out.append(pending[0])
            pending[0] = None

    cpu.trace = hook
    cpu.run_until({TABLE_STAGE_DONE})
    return out


def main():
    doc = {"description": "Per-step decisions from $1555 and $1583 in the "
                          "original 6502. Inputs, the advanced coordinate, and "
                          "the LFSR state before and after. No map data.",
           "cases": []}
    for seed, config, index, label, cap in CASES:
        steps = capture(seed, config, index, cap)
        moved = sum(1 for s in steps
                    if (s["outX"], s["outY"]) != (s["inX"], s["inY"]))
        doc["cases"].append({"label": label, "seed": seed, "config": config,
                             "steps": steps})
        print(f"  {label:<10} {len(steps):3d} steps, {moved} advanced, "
              f"{len(steps) - moved} held", flush=True)
    path = f"{FIX}/stepper_reference.json"
    json.dump(doc, open(path, "w"), indent=1)
    print(f"\nwrote -> {os.path.relpath(path, ROOT)} "
          f"({os.path.getsize(path):,} bytes)")


if __name__ == "__main__":
    main()
