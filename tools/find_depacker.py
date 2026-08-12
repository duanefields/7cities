#!/usr/bin/env python3
"""SUPERSEDED — there is no depacker. Kept only as a record of the attempt.

This hunted a decompressor on the premise that `game` was packed. It is not
packed: it is the same size in RAM as on disk and is transformed by a **fixed
byte substitution**, recovered in full and now implemented statically in
`decrypt_game.py` and `SevenCitiesCore/GameCipher.swift`. Nothing here is on any
current path.

The watchpoint strategy below also never fired, which is worth remembering
before reaching for watchpoints again in this project.

Original description follows.

    Set a write watchpoint inside the game's memory range and let the machine
    tell us who writes there. The fastloader writes once as it streams sectors
    in; the depacker writes again with different data. Collecting the distinct
    program counters that store to one address separates them.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402

ROOT = "/Users/duane/Code/7cities"
DISK1 = f"{ROOT}/d64/7CITIES1.D64"
WATCH = 0x5000              # comfortably inside game.prg's range
HITS = 24


def warp(on):
    call("vice_machine_config_set", resources={"WarpMode": 1 if on else 0})


def clear():
    for cp in call("vice_checkpoint_list")["checkpoints"]:
        call("vice_checkpoint_delete", checkpoint_num=cp["checkpoint_num"])


def paused():
    return call("vice_ping")["execution"] == "paused"


def wait_paused(timeout=60):
    end = time.time() + timeout
    while time.time() < end:
        if not paused():
            break
        time.sleep(0.05)
    while time.time() < end:
        if paused():
            return True
        time.sleep(0.05)
    return False


def main():
    from PIL import Image, ImageChops
    tpl = Image.open(f"{ROOT}/local/menu_template.png").convert("L")
    scratch = f"{ROOT}/local/_depack.png"

    clear()
    call("vice_execution_run")
    warp(True)
    call("vice_machine_reset", mode="hard")
    time.sleep(3)
    call("vice_disk_detach", unit=8)
    time.sleep(1)
    call("vice_disk_attach", unit=8, path=DISK1)
    call("vice_autostart", path=DISK1)
    time.sleep(22)

    warp(False)
    for i in range(150):
        call("vice_display_screenshot", path=scratch)
        img = Image.open(scratch).convert("L")
        h = ImageChops.difference(tpl, img).histogram()
        if sum(h[40:]) / sum(h) < 0.02:
            print(f"title menu at poll {i}", flush=True)
            break
        time.sleep(0.6)
    else:
        raise SystemExit("never saw the title menu")

    # Watch writes to one address inside the game's range, then start the load.
    call("vice_checkpoint_add", start=f"${WATCH:04X}", exec=False, store=True,
         stop=True)
    call("vice_keyboard_key_press", key="F7")
    warp(True)

    seen = {}
    for n in range(HITS):
        if not wait_paused():
            print(f"no further writes after {n} hits", flush=True)
            break
        pc = call("vice_registers_get")["PC"]
        val = call("vice_memory_read", address=f"${WATCH:04X}", size=1,
                   encoding="hex")["data_hex"]
        seen.setdefault(pc, []).append(val)
        print(f"  hit {n:2d}: PC=${pc:04X} wrote ${val}", flush=True)
        call("vice_execution_run")
        time.sleep(0.05)

    clear()
    call("vice_execution_run")
    print("\ndistinct writers:")
    for pc, vals in sorted(seen.items()):
        print(f"  ${pc:04X}  {len(vals)} write(s), values {vals[:6]}")


if __name__ == "__main__":
    main()
