#!/usr/bin/env python3
"""Capture the walker's candidate test, `$1A00`, from the original.

`$1A00` decides whether the walk may step somewhere: the offset must sit on the
coastline circle within a tolerance of three, and the row must be clear for about
ten cells either side. It is the gate that shapes every landmass, and its two
horizontal scans are asymmetric in ways that are easy to transcribe wrongly.

Records the state going in and the carry coming out — clear accepts, set rejects
— along with the metric and working radius, so a disagreement says whether the
circle test or the clearance scan is at fault.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, TABLE_STAGE_DONE  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"
FILL, TEST, RET_ACCEPT = 0x23D3, 0x1A00, 0x1A46
# $1A00 has *two* reject exits, and the early one carries most of the traffic:
# $1A05 returns straight after $19EE refuses the circle test, while $1A24 is the
# clearance scan finding land. Hooking only $1A24 captured 7 calls out of the 421
# the phase actually makes.
RET_REJECT = (0x1A05, 0x1A24)
# Just past `JSR $13E0` inside $1A00, where $0C holds the resolved column and
# $29/$2A point at the row. The clearance scan reads cells around that column, so
# a port cannot be checked on it without them; the circle test needs no mask at
# all, which is why most cases are testable without this.
RESOLVED = 0x1A0D
SCAN_REACH = 12
CASES = [(0x1234, 0, 1, "satellite", 40), (0x1234, 0, 4, "island", 60),
         (0x1234, 0, 0, "continent", 60)]


def capture(seed, config, index, cap):
    cpu = machine(seed, config)
    seen, pending, out, done = [0], [None], [], [False]

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
        if pc == TEST:
            pending[0] = {"dx": cpu.rd(0x14), "dy": cpu.rd(0x15),
                          "heading": cpu.rd(0x1A), "workingRadius": cpu.rd(0x21),
                          "radius": cpu.rd(0xB0), "drift": cpu.rd(0xB3),
                          "centerX": cpu.rd(0x22),
                          "centerY": cpu.rd(0x23) | cpu.rd(0x24) << 8}
        elif pending[0] and pc == RESOLVED:
            column = cpu.rd(0x0C)
            row = ((cpu.rd(0x2A) << 8 | cpu.rd(0x29)) - 0x5700) >> 5
            cells = {}
            for d in range(-SCAN_REACH, SCAN_REACH + 1):
                x = (column + d) & 0xFF
                byte = cpu.mem[0x5700 + row * 32 + (x >> 3)]
                cells[str(x)] = 1 if byte & (0x80 >> (x & 7)) else 0
            pending[0].update(column=column, row=row, cells=cells)
        elif pending[0] and (pc == RET_ACCEPT or pc in RET_REJECT):
            pending[0]["accepted"] = (pc == RET_ACCEPT)
            pending[0]["rejectedBy"] = (
                None if pc == RET_ACCEPT
                else "circle" if pc == 0x1A05 else "clearance")
            pending[0]["workingRadiusAfter"] = cpu.rd(0x21)
            out.append(pending[0])
            pending[0] = None

    cpu.trace = hook
    cpu.run_until({TABLE_STAGE_DONE})
    return out


def main():
    doc = {"description": "Candidate tests from $1A00 in the original 6502. "
                          "State in, accept or reject out. No map data.",
           "cases": []}
    for seed, config, index, label, cap in CASES:
        tests = capture(seed, config, index, cap)
        ok = sum(1 for t in tests if t["accepted"])
        doc["cases"].append({"label": label, "tests": tests})
        print(f"  {label:<10} {len(tests):3d} tests, {ok} accepted, "
              f"{len(tests) - ok} rejected", flush=True)
    path = f"{FIX}/validation_reference.json"
    json.dump(doc, open(path, "w"), indent=1)
    print(f"\nwrote -> {os.path.relpath(path, ROOT)} "
          f"({os.path.getsize(path):,} bytes)")


if __name__ == "__main__":
    main()
