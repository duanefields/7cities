#!/usr/bin/env python3
"""Capture RAM at the land-mass phase entry, so the interpreter can start there.

`sim6502.py` has no 1541. The World Maker's initialization talks to the drive
over the serial bus — `$13BC` reads `$DD00` twice to debounce and shifts the DATA
line into carry, and `$1287`/`$128C` spin on it — so running from `$1E99` in the
interpreter waits forever for a drive that does not exist.

Everything from `$212A` onward is computation over RAM, which is the part worth
simulating. So let the emulator do the boot, stop somewhere early, and dump the
machine. The interpreter picks up from there.

**The stop address cannot be controlled, so do not try.** VICE's checkpoints halt
reliably — the machine really is paused and stays paused — but they halt *late*,
overshooting the target by a variable amount: measured landings for a checkpoint
on `$212A` were `$143A`, `$0AF6` and `$230E`, and disabling warp did not help.

That does not matter here. The interpreter needs a *consistent* state, not a
particular one, so this records wherever the machine actually stopped along with
the full register set, and `sim_landmass.py` resumes from exactly that. RAM is
read only while paused, and the PC is checked before and after the dump so a torn
snapshot is rejected rather than silently used.

Snapshots are 64 KB of RAM containing the game's own code, so they are game data:
they go to `local/`, which is gitignored, and must never be committed.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from wm_trace import dump, clear_checkpoints  # noqa: E402
from wm_config import boot, arm, wait_hit, ENTRY  # noqa: E402
from wm_deterministic import apply_patches  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = f"{ROOT}/local/snapshots"
PHASE_START = 0x212A

SEEDS = [0x1234, 0xBEEF, 0x0001]
CONFIGS = [0, 1, 2]


def capture(code, seed, config):
    boot(code)
    apply_patches(seed, config)
    num = arm(PHASE_START)
    call("vice_keyboard_type", text=f"SYS {ENTRY}\n")
    if not wait_hit(num, timeout=300):
        raise SystemExit(f"seed ${seed:04X} config {config}: never reached "
                         f"${PHASE_START:04X}")

    # Pause explicitly. A checkpoint halt alone does not survive a long read
    # sequence: an earlier version dumped 64 KB across a resuming machine and
    # produced torn snapshots whose PCs were $1B51, $1B54, $1438 and $2373.
    call("vice_execution_pause")
    regs = call("vice_registers_get")
    ram = dump(0x0000, 0xFFFF, bank="ram")

    # Reject a torn snapshot rather than using one: the state must not have
    # moved while the dump was in flight.
    after = call("vice_registers_get")
    if after["PC"] != regs["PC"] or after["SP"] != regs["SP"]:
        raise SystemExit(f"seed ${seed:04X} config {config}: state moved during "
                         f"the dump (${regs['PC']:04X} -> ${after['PC']:04X})")
    clear_checkpoints()
    return ram, regs


def main():
    os.makedirs(OUT, exist_ok=True)
    code = open(f"{ROOT}/local/game3.bin", "rb").read()
    index = []
    for seed in SEEDS:
        for config in CONFIGS:
            ram, regs = capture(code, seed, config)
            name = f"{seed:04X}_{config}"
            open(f"{OUT}/{name}.ram", "wb").write(ram)
            flags = sum(bit for name, bit in (("N", 0x80), ("V", 0x40),
                                              ("B", 0x10), ("D", 0x08),
                                              ("I", 0x04), ("Z", 0x02),
                                              ("C", 0x01)) if regs.get(name))
            index.append({"seed": seed, "config": config, "file": f"{name}.ram",
                          "pc": regs["PC"], "a": regs["A"], "x": regs["X"],
                          "y": regs["Y"], "sp": regs["SP"], "p": flags | 0x20})
            print(f"  seed ${seed:04X} config {config}: PC=${regs['PC']:04X} "
                  f"SP=${regs['SP']:02X} P=${flags | 0x20:02X} -> {name}.ram",
                  flush=True)
    with open(f"{OUT}/index.json", "w") as f:
        json.dump({"phaseStart": PHASE_START, "snapshots": index}, f, indent=1)
    print(f"\nwrote {len(index)} snapshots -> {os.path.relpath(OUT, ROOT)} "
          f"(gitignored; these are game data)")


if __name__ == "__main__":
    main()
