#!/usr/bin/env python3
"""Capture the step evaluator `$1476` from the original.

`$1476` is the main candidate test — the one that actually shapes a coastline,
as distinct from `$1A00`, which only validates positions restored during an
unwind. For each of nine directions it proposes an offset, counts land in a 3x3
block around it, and accepts or refuses.

Records the direction indices going in, the proposed candidate, the neighbour
count the original accumulated, and the verdict. The 3x3 block reads the mask, so
those nine cells are recorded too — without them a port cannot be checked on the
half of the routine that matters.
"""
import json, os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, TABLE_STAGE_DONE  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"
FILL, EVAL, SCAN_DONE = 0x23D3, 0x1476, 0x150C
# Just after `JSR $141C` builds the row pointer and before the scan loop runs.
# Reading the pointer at $150C instead gives the row the loop *ended* on: the
# outer loop calls $289D once per iteration, so it sits three rows below the
# origin. The column is safe either way because the loop advances $02, not $0C.
SCAN_START = 0x14D3
REJECT_EARLY, REJECT, ACCEPT_LO, ACCEPT_HI = 0x14B9, 0x1535, 0x1550, 0x1552
CASES = [(0x1234, 0, 1, "satellite", 50), (0x1234, 0, 4, "island", 60),
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
        if pc == EVAL:
            pending[0] = {"direction": cpu.rd(0x1D),
                          "horizontalBase": cpu.rd(0x1B),
                          "verticalBase": cpu.rd(0x1C),
                          "dx": cpu.rd(0x14), "dy": cpu.rd(0x15),
                          "heading": cpu.rd(0x1A), "edgeFlag": cpu.rd(0x0E),
                          "workingRadius": cpu.rd(0x21), "radius": cpu.rd(0xB0),
                          "drift": cpu.rd(0xB3), "centerX": cpu.rd(0x22),
                          "centerY": cpu.rd(0x23) | cpu.rd(0x24) << 8}
        elif pending[0] and pc == SCAN_START:
            col = cpu.rd(0x0C)
            row = ((cpu.rd(0x2A) << 8 | cpu.rd(0x29)) - 0x5700) >> 5
            cells = {}
            # The scan runs from the origin down and right, not centred on it:
            # $0C and the row pointer have already been decremented, so the
            # nine cells are origin..origin+2 on each axis.
            for dy in range(0, 3):
                for dx in range(0, 3):
                    x = (col + dx) & 0xFF
                    r = row + dy
                    if 0 <= r < 464:
                        byte = cpu.mem[0x5700 + r * 32 + (x >> 3)]
                        cells[f"{x},{r}"] = 1 if byte & (0x80 >> (x & 7)) else 0
            pending[0].update(scanColumn=col, scanRow=row, cells=cells)
        elif pending[0] and pc == SCAN_DONE:
            pending[0]["candidateDx"] = cpu.rd(0x16)
            pending[0]["candidateDy"] = cpu.rd(0x17)
            pending[0]["counters"] = [cpu.rd(0x35 + i) for i in range(9)]
            pending[0]["seed3D"] = cpu.rd(0x3D)
        elif pending[0] and pc in (REJECT_EARLY, REJECT, ACCEPT_LO, ACCEPT_HI):
            pending[0]["accepted"] = pc in (ACCEPT_LO, ACCEPT_HI)
            pending[0]["rejectedBy"] = ("edge" if pc == REJECT_EARLY
                                        else "scan" if pc == REJECT else None)
            out.append(pending[0])
            pending[0] = None

    cpu.trace = hook
    cpu.run_until({TABLE_STAGE_DONE})
    return out


def main():
    doc = {"description": "Step evaluator $1476 from the original 6502: the "
                          "proposed candidate, the 3x3 neighbour count and the "
                          "verdict. No map data.", "cases": []}
    for seed, config, index, label, cap in CASES:
        evals = capture(seed, config, index, cap)
        ok = sum(1 for e in evals if e.get("accepted"))
        scanned = sum(1 for e in evals if "counters" in e)
        doc["cases"].append({"label": label, "evaluations": evals})
        print(f"  {label:<10} {len(evals):3d} evaluations, {ok} accepted, "
              f"{scanned} reached the scan", flush=True)
    path = f"{FIX}/evaluator_reference.json"
    json.dump(doc, open(path, "w"), indent=1)
    print(f"\nwrote -> {os.path.relpath(path, ROOT)} "
          f"({os.path.getsize(path):,} bytes)")


if __name__ == "__main__":
    main()
