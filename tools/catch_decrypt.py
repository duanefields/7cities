#!/usr/bin/env python3
"""Capture `game` at the instant it is decrypted, before the game modifies it.

`watch_unpack.py` established the sequence: pressing F7 loads `game` verbatim
into `$0800-$94FF` (99.60% match against the on-disk file), and a few seconds
later the whole range turns into real 6502 in place — `JSR` count jumps from 66
to 1114. Same size in, same size out, so it is an in-place cipher.

That gives a known plaintext/ciphertext pair, which is the fastest route to the
cipher. But a dump taken later is contaminated: the game runs for however long
it takes to notice, zeroing buffers and writing variables, which is enough to
wreck a byte-level comparison. So poll a small window until it stops matching
the file, **pause the machine immediately**, and dump while it is frozen.

Writes `local/game_plain.bin`, the clean plaintext.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from watch_unpack import boot, wait_for_menu, tap, warp, dump, BAND  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROBE_LO, PROBE_N = 0x1000, 0x100      # small window, cheap to poll


def main():
    from PIL import Image
    ct = open(f"{ROOT}/local/game.bin", "rb").read()
    probe_ref = ct[PROBE_LO - 0x0800:PROBE_LO - 0x0800 + PROBE_N]
    tpl = Image.open(f"{ROOT}/local/menu_template.png").convert("L").crop(BAND)
    scratch = f"{ROOT}/local/_catch.png"

    for attempt in range(3):
        print(f"boot attempt {attempt + 1}", flush=True)
        boot()
        if wait_for_menu(tpl, scratch):
            break
        print("  no menu; rebooting", flush=True)
    else:
        raise SystemExit("never saw the menu band after 3 boots")

    print("menu detected; pressing F7", flush=True)
    tap("F7")
    warp(True)

    # Phase 1: wait for the probe window to match the file, i.e. the load has
    # reached it. Phase 2: wait for it to stop matching, i.e. decryption ran.
    def probe():
        r = call("vice_memory_read", address=f"${PROBE_LO:04X}", size=PROBE_N,
                 bank="ram", encoding="hex")["data_hex"]
        return bytes.fromhex(r)

    loaded = False
    for i in range(1200):
        cur = probe()
        same = sum(1 for a, b in zip(cur, probe_ref) if a == b)
        if not loaded and same > PROBE_N * 0.95:
            loaded = True
            print(f"  loaded verbatim at poll {i}", flush=True)
        elif loaded and same < PROBE_N * 0.2:
            call("vice_execution_pause")
            print(f"  DECRYPTED at poll {i} — machine paused", flush=True)
            break
        time.sleep(0.15)
    else:
        raise SystemExit("never saw the decryption")

    plain = dump(0x0800, 0x94FF)
    out = f"{ROOT}/local/game_plain.bin"
    open(out, "wb").write(plain)
    print(f"wrote {out}: JSR={plain.count(0x20)} RTS={plain.count(0x60)} "
          f"AND#0F={plain.count(0x29)}")
    print(f"PC at pause: ${call('vice_registers_get')['PC']:04X}")


if __name__ == "__main__":
    main()
