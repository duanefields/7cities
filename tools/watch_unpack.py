#!/usr/bin/env python3
"""Settle what the `game` file is by watching `$0800` while it loads.

`game` loads at `$0800` and is 36,096 bytes, so it occupies exactly
`$0800-$94FF`. It is not code (66 `JSR`), not plain graphics, not a constant
XOR of any expected word, and not bit-transposed — see NOTES.md for the full
elimination table. Static analysis has run out of road, and the two remaining
readings differ in a way that is easy to observe:

1. `game` is packed, and something expands it in place. Then RAM at `$0800`
   should first match the on-disk file, and later stop matching as `JSR`
   density jumps.
2. `game` is never loaded. Then RAM at `$0800` should **never** match the file,
   and code should appear there without a matching-then-diverging phase.

So sample `$0800-$94FF` on a timer and record, for each sample, how much it
matches the file and how code-like it is. The shape of those two curves answers
the question directly.

Requires vice-mcp (a VICE fork with MCP built in, not Homebrew VICE) and a
title-menu template to sync the F7 press against — same approach as
`dump_game.py`, which this borrows from.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK1 = f"{ROOT}/d64/7CITIES1.D64"
LO, HI = 0x0800, 0x94FF
SAMPLES, INTERVAL = 60, 3.0
KEY = os.environ.get("WATCH_KEY", "F7")   # F7 plays, F1 runs the World Maker

COMMON = {0xA9, 0xA2, 0xA0, 0x85, 0x8D, 0x20, 0x60, 0x4C, 0xAD, 0xA5, 0xE8,
          0xC8, 0xCA, 0x88, 0x29, 0xC9, 0xD0, 0xF0, 0x90, 0xB0, 0x91, 0xB1}


def warp(on):
    call("vice_machine_config_set", resources={"WarpMode": 1 if on else 0})


def dump(lo, hi):
    out, a = bytearray(), lo
    while a <= hi:
        n = min(0x1000, hi - a + 1)
        out += bytes.fromhex(call("vice_memory_read", address=f"${a:04X}",
                                  size=n, bank="ram", encoding="hex")["data_hex"])
        a += n
    return bytes(out)


def main():
    disk = open(f"{ROOT}/local/game.bin", "rb").read()

    for cp in call("vice_checkpoint_list")["checkpoints"]:
        call("vice_checkpoint_delete", checkpoint_num=cp["checkpoint_num"])
    call("vice_execution_run")
    warp(True)
    call("vice_machine_reset", mode="hard")
    time.sleep(3)
    call("vice_disk_detach", unit=8)
    time.sleep(1)
    call("vice_disk_attach", unit=8, path=DISK1)
    call("vice_autostart", path=DISK1)
    time.sleep(25)
    warp(False)                      # the menu's poll window is short

    # Matching a screenshot against a template picked the title *animation*
    # rather than the menu, so F7 landed before anything was listening. Instead
    # sample straight through and re-press every few seconds: pressing F7 when
    # no menu is up costs nothing, and one of them lands.
    print(f"{'t':>6} {'match%':>8} {'JSR':>6} {'opcode%':>8}")
    rows = []
    for i in range(SAMPLES):
        if i % 3 == 0:
            call("vice_keyboard_key_press", key=KEY)
        time.sleep(INTERVAL)
        ram = dump(LO, HI)
        match = sum(1 for a, b in zip(disk, ram) if a == b) / len(ram) * 100
        jsr = ram.count(0x20)
        dens = sum(1 for x in ram if x in COMMON) / len(ram) * 100
        print(f"{i * INTERVAL:6.0f} {match:8.2f} {jsr:6d} {dens:8.1f}", flush=True)
        rows.append((i * INTERVAL, match, jsr, dens))

    peak = max(rows, key=lambda r: r[1])
    print(f"\npeak match {peak[1]:.2f}% at t={peak[0]:.0f}s")
    if peak[1] > 90:
        print("=> `game` IS loaded verbatim and then transformed in place: "
              "a depacker exists. Break on writes to $0800 around that moment.")
    elif peak[1] < 5:
        print("=> `game` is never loaded here. The code at $0800 comes from "
              "another stage, and `game` is likely a decoy.")
    else:
        print("=> inconclusive; widen SAMPLES/INTERVAL or check the F7 sync.")


if __name__ == "__main__":
    main()
