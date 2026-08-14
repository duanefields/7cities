#!/usr/bin/env python3
"""What the mask unpack counts, and what `$40FA` turns it into.

`$47DF` does not decide how many villages a band may have. That is settled two
phases earlier: `$0C9B` walks the finished mask, `$1047` and `$1060` count the
quadrants with enough land in them, and `$40FA` turns the two counts into the
budget and the threshold the village phase reads out of zero page.

None of that is reachable from the land-mass phase alone — `$0C9B` runs after
it, on the way into the pipeline — so this needs the virtual drive like the
other pipeline captures do. It stops as soon as `$40FA` has run, which is early,
so it is much cheaper than a whole World Maker run.

Numbers only. No map data.
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, PHASE_DONE  # noqa: E402
from vdrive import VirtualDrive  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"

BUDGET_DONE = 0x0D60      # just past `JSR $40FA`
QUADRANT = 0x1082         # where `$1060` has its count in `$52`


def capture(seed, config):
    cpu = machine(seed, config)
    cpu.run_until({PHASE_DONE}, max_steps=40_000_000)
    cpu.step()
    VirtualDrive().attach(cpu)
    inner = cpu.trace or ((lambda pc, op: None))

    evaluated = [0]

    def hook(pc, op):
        if pc == QUADRANT:
            evaluated[0] += 1
        inner(pc, op)

    cpu.trace = hook
    cpu.run_until({BUDGET_DONE}, max_steps=200_000_000)

    def word(low):
        return cpu.rd(low) | cpu.rd(low + 1) << 8

    return {"seed": seed, "config": config,
            "quadrantsEvaluated": evaluated[0],
            "northEligible": word(0x70), "southEligible": word(0x72),
            "villages": [cpu.rd(0x6C), cpu.rd(0x6D)],
            "threshold": [cpu.rd(0x6E), cpu.rd(0x6F)],
            "82": [cpu.rd(0x82), cpu.rd(0x83)],
            # `$41BB` takes these off the budgets: the second wave's island
            # counts and, from `$1BD6`, how many small landmasses were filed
            # into each position table.
            "islands": [cpu.rd(0x67), cpu.rd(0x68)],
            "smallLandmasses": [cpu.rd(0xA8), cpu.rd(0xA9)]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", default="0x1234")
    parser.add_argument("--configs", default="0,1,2")
    args = parser.parse_args()

    seed = int(args.seed, 0)
    runs = []
    for config in [int(c) for c in args.configs.split(",")]:
        entry = capture(seed, config)
        runs.append(entry)
        print(f"seed ${seed:04X} config {config}: "
              f"{entry['quadrantsEvaluated']} quadrants evaluated, "
              f"{entry['northEligible']} north / {entry['southEligible']} south "
              f"eligible, villages {entry['villages']}, "
              f"threshold {entry['threshold']}")

    path = f"{FIX}/village_reference.json"
    have = []
    if os.path.exists(path):
        have = [r for r in json.load(open(path))["runs"]
                if (r["seed"], r["config"]) not in
                {(e["seed"], e["config"]) for e in runs}]
    runs = sorted(have + runs, key=lambda r: (r["seed"], r["config"]))
    with open(path, "w") as handle:
        json.dump({"description": "What $0C9B's quadrant count and $40FA's "
                                  "arithmetic leave in zero page for $47DF to "
                                  "read. Counts only. No map data.",
                   "runs": runs}, handle, indent=1)
    print(f"wrote {os.path.relpath(path, ROOT)}")


if __name__ == "__main__":
    main()
