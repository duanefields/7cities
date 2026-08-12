#!/usr/bin/env python3
"""Dump the main game binary from RAM after it has unpacked itself.

`game.prg` is packed on disk — 36 KB containing only 66 JSR and zero
`AND #$0F`, against 938 JSR in the 18 KB `game3`. So it cannot be disassembled
statically. Boot the game under vice-mcp, let it unpack, and read RAM instead.

Menu input goes through the KERNAL buffer (`vice_keyboard_key_press`), and the
title screen only polls while its menu text is displayed, so the F7 press is
synced to a screenshot match rather than a fixed delay.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402

DISK1 = "/Users/duane/Code/7cities/d64/7CITIES1.D64"
MENU_TEMPLATE = None      # set via argv[2]


def warp(on):
    call("vice_machine_config_set", resources={"WarpMode": 1 if on else 0})


def shot(path):
    call("vice_display_screenshot", path=path)
    from PIL import Image
    return Image.open(path).convert("L")


def looks_like(img, template, tol=0.02):
    from PIL import ImageChops
    hist = ImageChops.difference(template, img).histogram()
    return sum(hist[40:]) / sum(hist) < tol


def dump(lo, hi, bank="ram"):
    out = bytearray()
    a = lo
    while a <= hi:
        n = min(0x1000, hi - a + 1)
        r = call("vice_memory_read", address=f"${a:04X}", size=n, bank=bank,
                 encoding="hex")
        out += bytes.fromhex(r["data_hex"])
        a += n
    return bytes(out)


def density(buf):
    """Rough instruction density — packed code scores far lower."""
    return buf.count(0x20), buf.count(0xD0), buf.count(0x60)


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else "local"
    template_path = sys.argv[2]
    from PIL import Image
    template = Image.open(template_path).convert("L")
    scratch = os.path.join(outdir, "_poll.png")

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

    warp(False)                       # menu poll window is too short under warp
    for i in range(150):
        if looks_like(shot(scratch), template):
            print(f"menu matched at poll {i}; sending F7", flush=True)
            call("vice_keyboard_key_press", key="F7")
            break
        time.sleep(0.6)
    else:
        raise SystemExit("never saw the title menu")

    warp(True)
    print("waiting for the game program to load and unpack", flush=True)
    best = None
    for i in range(40):
        time.sleep(3)
        buf = dump(0x0800, 0x94FF)
        jsr, bne, rts = density(buf)
        if best is None or jsr > best[0]:
            best = (jsr, bne, rts, buf)
        if jsr > 600:                 # unpacked code looks like game3's density
            print(f"unpacked after ~{i * 3}s: JSR={jsr} BNE={bne} RTS={rts}",
                  flush=True)
            break
    jsr, bne, rts, buf = best
    dest = os.path.join(outdir, "game_unpacked.bin")
    open(dest, "wb").write(buf)
    call("vice_display_screenshot", path=os.path.join(outdir, "_state.png"))
    print(f"wrote {dest}: {len(buf)} bytes, JSR={jsr} BNE={bne} RTS={rts}")

    disk = open("local/game.bin", "rb").read()
    same = sum(1 for a, b in zip(disk, buf) if a == b)
    print(f"matches on-disk image in {100 * same / len(buf):.1f}% of bytes")


if __name__ == "__main__":
    main()
