#!/usr/bin/env python3
"""Where the port's mountain ranges first disagree with the original's.

`range_trace.py` records every write the original makes, and the disabled test
`debugRangeWrites` records every write the port makes. A digest says the two
differ; this says which cell, in which stage, and what was around it — which is
the difference between knowing a routine is wrong and knowing why.

Both files live in `local/` and neither may be committed: they are lists of map
cells.

    tools/range_diff.py [band] [config]
"""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTEXT = 6


def load_original(band, config):
    """The original's writes for one band, flattened, tagged by stage."""
    trace = json.load(open(f"{ROOT}/local/range_trace_{config}.json"))
    out = []
    for entry in trace[band]:
        for x, y, value, stage in entry["writes"]:
            out.append((stage, x, y, value))
    return out


def load_port():
    out = []
    for segment in json.load(open(f"{ROOT}/local/port_range_trace.json")):
        for x, y, value in segment["writes"]:
            out.append((segment["stage"], x, y, value))
    return out


def main():
    band = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    config = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    original, port = load_original(band, config), load_port()
    print(f"original {len(original)} writes, port {len(port)}")

    stages = {}
    for stage, *_ in original:
        stages[stage] = stages.get(stage, 0) + 1
    print(f"  original by stage: {stages}")
    stages = {}
    for stage, *_ in port:
        stages[stage] = stages.get(stage, 0) + 1
    print(f"  port by stage:     {stages}")

    for i in range(min(len(original), len(port))):
        if original[i] != port[i]:
            print(f"\nfirst divergence at write {i}:")
            lo = max(0, i - CONTEXT)
            for j in range(lo, min(len(original), len(port), i + CONTEXT + 1)):
                flag = "  <-- " if j == i else "      "
                print(f"  {j:6d} original {original[j]}"
                      f"{flag}port {port[j]}")
            return
    if len(original) != len(port):
        shorter = "port" if len(port) < len(original) else "original"
        print(f"\nno divergence in the common prefix; the {shorter} stops first")
    else:
        print("\nidentical")


if __name__ == "__main__":
    main()
