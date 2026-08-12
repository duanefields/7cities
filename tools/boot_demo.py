#!/usr/bin/env python3
"""Boot the game into its self-playing demo and capture an exploration frame.

Two gates had to be cracked to make this possible:

1. The title menu polls the KERNAL buffer only while its text is on screen, so
   the F7 press is synced to a screenshot match rather than a fixed delay.
2. The game validates a map disk by its *directory*. `d64/HISTMAP.D64` is
   `7CITIES2.D64` with the BAM and directory rewritten to look like World Maker
   output, and it is accepted.

With that disk attached the game runs OBSERVER (DEMO) mode, which plays itself
— so the exploration view is reachable with no joystick, which never worked.

Captures the screen matrix, color RAM and live charset, which together give the
real terrain-code to glyph mapping.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402

ROOT = "/Users/duane/Code/7cities"
DISK1 = f"{ROOT}/d64/7CITIES1.D64"
MAPDISK = f"{ROOT}/d64/HISTMAP.D64"
TERRAIN_LABEL = bytes([0x34, 0x25, 0x32, 0x32, 0x21, 0x29, 0x2E])   # "TERRAIN"


def warp(on):
    call("vice_machine_config_set", resources={"WarpMode": 1 if on else 0})


def rd(a, n, bank="ram"):
    r = call("vice_memory_read", address=f"${a:04X}", size=n, bank=bank,
             encoding="hex")
    return bytes.fromhex(r["data_hex"])


def shot(path):
    call("vice_display_screenshot", path=path)
    from PIL import Image
    return Image.open(path).convert("L")


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "local"
    from PIL import Image, ImageChops
    tpl = Image.open(f"{ROOT}/local/menu_template.png").convert("L")
    poll = os.path.join(out, "_poll.png")

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
    time.sleep(22)

    warp(False)
    for i in range(150):
        h = ImageChops.difference(tpl, shot(poll)).histogram()
        if sum(h[40:]) / sum(h) < 0.02:
            call("vice_keyboard_key_press", key="F7")
            print(f"title menu: F7 at poll {i}", flush=True)
            break
        time.sleep(0.6)
    else:
        raise SystemExit("never saw the title menu")

    warp(True)
    time.sleep(25)
    call("vice_disk_detach", unit=8)
    time.sleep(2)
    call("vice_disk_attach", unit=8, path=MAPDISK)
    time.sleep(2)
    warp(False)
    for _ in range(4):                 # this screen wants the matrix as well
        call("vice_keyboard_matrix", key="F7", hold_frames=12)
        time.sleep(1.0)
        call("vice_keyboard_key_press", key="F7")
        time.sleep(1.0)
    print("map disk accepted, demo starting", flush=True)

    for i in range(90):
        v = call("vice_vicii_get_state")
        mp = v["memory_pointers"]
        vm = 0x8000 + ((mp >> 4) & 0xF) * 1024
        ch = 0x8000 + ((mp >> 1) & 7) * 2048
        scr = rd(vm, 1024)
        if TERRAIN_LABEL in scr:
            open(os.path.join(out, "exp_screen.bin"), "wb").write(scr)
            open(os.path.join(out, "exp_col.bin"), "wb").write(
                rd(0xD800, 1024, bank="cpu"))
            open(os.path.join(out, "exp_charset.bin"), "wb").write(rd(ch, 2048))
            call("vice_display_screenshot",
                 path=os.path.join(out, "exp_shot.png"))
            bg = [call("vice_memory_read", address=f"${a:04X}", size=1,
                       bank="cpu", encoding="hex")["data_hex"]
                  for a in (0xD021, 0xD022, 0xD023)]
            print(f"exploration frame at poll {i}: vm=${vm:04X} charset=${ch:04X} "
                  f"mode={v['video_mode']} bg={bg}", flush=True)
            return
        time.sleep(1.5)
    print("no exploration frame seen", flush=True)


if __name__ == "__main__":
    main()
