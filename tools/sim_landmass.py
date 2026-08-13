#!/usr/bin/env python3
"""Run the World Maker's land-mass phase in the interpreter, not the emulator.

If this reproduces the mask digests captured from VICE, then `sim6502.py` is
trustworthy on the real workload and not merely on the arithmetic self-test — and
from then on the walker can be single-stepped, traced and diffed in-process
instead of over MCP.

**Start from a snapshot, not from `$1E99`.** The World Maker's initialization
talks to the 1541 over the serial bus, and the interpreter has no drive: running
from the real entry point spins forever in `$13BC`, which reads `$DD00` twice to
debounce and shifts the DATA line into carry. Measured, that is 855,591 reads of
`$DD00` and no progress.

Everything from `$212A` onward is computation over RAM. So `wm_snapshot.py` lets
the emulator do the boot and dumps the machine early in the phase, and this picks
up from exactly that state — RAM, registers and flags.

The snapshot's PC is wherever VICE actually halted, which is not controllable:
its checkpoints stop reliably but late, overshooting by a variable amount. That
is fine, because resuming needs a *consistent* state rather than a particular
one.

`$D012` still needs to read `$FE` or the raster sync at `$0A49` spins: there are
no interrupts here to advance it.
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim6502 import Sim6502  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures"

GAME3_LOAD = 0x0800
ENTRY = 0x1E99
F7_WAIT_BRANCH = 0x1F8A
SEED_SITE = 0x20CB
STIR_SITE = 0x2406
SELECTOR = 0x2146
TABLE_STAGE_DONE = 0x280A
PHASE_DONE = 0x2894
BASE = 0x5700
MASK_BYTES = 400 * 32


SNAPSHOTS = f"{ROOT}/local/snapshots"


def machine(seed, config):
    """A CPU primed from the emulator snapshot taken at `$212A`."""
    index = json.load(open(f"{SNAPSHOTS}/index.json"))
    entry = next(s for s in index["snapshots"]
                 if s["seed"] == seed and s["config"] == config)
    cpu = Sim6502(open(f"{SNAPSHOTS}/{entry['file']}", "rb").read())
    # $D012 always reads $FE so the raster sync at $0A49 falls through.
    cpu.io_read = lambda a: 0xFE if a == 0xD012 else 0x00
    cpu.pc = entry["pc"]
    cpu.a, cpu.x, cpu.y, cpu.sp = entry["a"], entry["x"], entry["y"], entry["sp"]
    cpu.p = entry["p"]          # flags matter: the code branches on carry across calls
    return cpu


def run(code, seed, config):
    cpu = machine(seed, config)
    stages = {}
    pc, n = cpu.run_until({TABLE_STAGE_DONE})
    stages["tableStage"] = bytes(cpu.mem[BASE:BASE + MASK_BYTES])
    steps = n
    cpu.step()                                  # move off the stop address
    pc, n = cpu.run_until({PHASE_DONE})
    stages["phaseEnd"] = bytes(cpu.mem[BASE:BASE + MASK_BYTES])
    return stages, steps + n


def main():
    code = open(f"{ROOT}/local/game3.bin", "rb").read()
    ref = json.load(open(f"{FIX}/landmass_reference.json"))
    failures = 0
    for case in ref["cases"]:
        seed, config = case["seed"], case["config"]
        stages, steps = run(code, seed, config)
        line = [f"  seed ${seed:04X} config {config}: {steps:>10,} steps"]
        for stage in ("tableStage", "phaseEnd"):
            got = hashlib.sha256(stages[stage]).hexdigest()
            want = case[stage]["sha256"]
            ok = got == want
            failures += 0 if ok else 1
            line.append(f"{stage} {'ok' if ok else 'MISMATCH'}")
            if not ok:
                cells = sum(b.bit_count() for b in stages[stage])
                line.append(f"({cells} cells vs {case[stage]['landCells']})")
        print("  ".join(line), flush=True)
    print("\nPASS — the interpreter reproduces the original's masks" if not failures
          else f"\nFAIL — {failures} stage mismatches")
    return failures == 0


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
