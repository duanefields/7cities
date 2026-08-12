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
KEY = os.environ.get("WATCH_KEY", "F7")   # F7 plays, F3 runs the World Maker
MAP = os.environ.get("WATCH_MAP")         # map disk to swap in after the keypress
SWAP_AFTER = float(os.environ.get("WATCH_SWAP_AFTER", "6"))

COMMON = {0xA9, 0xA2, 0xA0, 0x85, 0x8D, 0x20, 0x60, 0x4C, 0xAD, 0xA5, 0xE8,
          0xC8, 0xCA, 0x88, 0x29, 0xC9, 0xD0, 0xF0, 0x90, 0xB0, 0x91, 0xB1}


FKEYS = ("F1", "F3", "F5", "F7")


def warp(on):
    call("vice_machine_config_set", resources={"WarpMode": 1 if on else 0})


def release_all():
    """Let go of every function key.

    `vice_keyboard_key_press` does **not** release. A press left F3 held
    (CIA1 `port_b` = `$DF` with `port_a` = `$FE`, which is row 0 bit 5 = F3),
    so every subsequent boot re-triggered the World Maker the instant the menu
    appeared, no matter how cleanly the machine was reset. Two runs were lost
    to it before the CIA state gave it away.
    """
    for k in FKEYS:
        call("vice_keyboard_key_release", key=k)


def tap(key, hold=0.12):
    call("vice_keyboard_key_press", key=key)
    time.sleep(hold)
    call("vice_keyboard_key_release", key=key)


def dump(lo, hi):
    out, a = bytearray(), lo
    while a <= hi:
        n = min(0x1000, hi - a + 1)
        out += bytes.fromhex(call("vice_memory_read", address=f"${a:04X}",
                                  size=n, bank="ram", encoding="hex")["data_hex"])
        a += n
    return bytes(out)


BAND = (0, 178, 384, 220)


def boot():
    """Hard reset and autostart disk 1.

    **`vice_machine_reset` does not take while the machine is running.** Two
    runs were lost to this: the reset reported "Machine power cycled", the
    autostart followed, and the machine carried on in the World Maker from the
    previous run with `PC` still inside `$0800-$4FFF`. Pausing first and then
    resetting lands at `$E5CF`, the KERNAL input loop, with the BASIC screen up.
    Always pause before reset.
    """
    for cp in call("vice_checkpoint_list")["checkpoints"]:
        call("vice_checkpoint_delete", checkpoint_num=cp["checkpoint_num"])
    warp(True)
    release_all()
    call("vice_disk_detach", unit=8)
    time.sleep(0.5)
    call("vice_execution_pause")
    call("vice_machine_reset", mode="hard")
    call("vice_execution_run")
    time.sleep(3)
    call("vice_disk_attach", unit=8, path=DISK1)
    time.sleep(1)
    call("vice_autostart", path=DISK1)
    time.sleep(25)
    warp(False)                      # the menu's poll window is short


def wait_for_menu(tpl, scratch, polls=700):
    """Poll for the menu band. Returns True if it appeared."""
    from PIL import Image, ImageChops
    for _ in range(polls):
        call("vice_display_screenshot", path=scratch)
        live = Image.open(scratch).convert("L").crop(BAND)
        h = ImageChops.difference(tpl, live).histogram()
        if sum(h[40:]) / sum(h) < 0.02:
            return True
        time.sleep(0.2)
    return False


def main():
    from PIL import Image
    disk = open(f"{ROOT}/local/game.bin", "rb").read()

    # Detecting the menu is the whole difficulty. Matching the *full* screen
    # against the template fires on the title animation, and re-pressing on a
    # timer misses the window because the title sequence loops. What is
    # distinctive is the band holding the two "PRESS F_ TO ..." lines: rows
    # 178-220 differ by 0.00% on the menu and at least 6.26% on the credits,
    # the finished title and mid-animation.
    tpl = Image.open(f"{ROOT}/local/menu_template.png").convert("L").crop(BAND)
    scratch = f"{ROOT}/local/_watch.png"

    for attempt in range(3):
        print(f"boot attempt {attempt + 1}", flush=True)
        boot()
        if wait_for_menu(tpl, scratch):
            break
        print("  no menu; rebooting", flush=True)
    else:
        raise SystemExit("never saw the menu band after 3 boots")

    print(f"menu detected; pressing {KEY}", flush=True)
    tap(KEY)
    warp(True)              # the transition and load are glacial otherwise

    # F7 on its own dissolves the title and returns to the attract loop without
    # loading, so it looks to check for a map disk first. `d64/HISTMAP.D64` is
    # accepted as one (NOTES.md), so offer it a few seconds in.
    if MAP:
        time.sleep(SWAP_AFTER)
        print(f"swapping in {os.path.basename(MAP)}", flush=True)
        call("vice_disk_detach", unit=8)
        time.sleep(0.5)
        call("vice_disk_attach", unit=8, path=MAP)

    print(f"{'t':>6} {'match%':>8} {'JSR':>6} {'opcode%':>8}")
    rows = []
    for i in range(SAMPLES):
        time.sleep(INTERVAL)
        ram = dump(LO, HI)
        match = sum(1 for a, b in zip(disk, ram) if a == b) / len(ram) * 100
        jsr = ram.count(0x20)
        dens = sum(1 for x in ram if x in COMMON) / len(ram) * 100
        print(f"{i * INTERVAL:6.0f} {match:8.2f} {jsr:6d} {dens:8.1f}", flush=True)
        rows.append((i * INTERVAL, match, jsr, dens))

    # Identify whatever ended up in RAM, over a wider range than $0800-$94FF
    # in case a stage loads high (the charset lives at $A800, for instance).
    wide = dump(0x0800, 0xBFFF)
    print("\nwhat is in RAM now:")
    for name in ("game", "game2", "game3", "game4", "stage1"):
        try:
            f = open(f"{ROOT}/local/{name}.bin", "rb").read()
        except FileNotFoundError:
            continue
        base = 0x1000 if name == "game4" else 0x0800
        seg = wide[base - 0x0800:base - 0x0800 + len(f)]
        n = min(len(f), len(seg))
        if n:
            same = sum(1 for a, b in zip(f[:n], seg[:n]) if a == b)
            print(f"    vs {name:7s} at ${base:04X}: {same * 100 / n:6.2f}%")

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
