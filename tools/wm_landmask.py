#!/usr/bin/env python3
"""Settle what lives at `$5700` during the World Maker's land-mass phase.

Reading the code says there are two different addressings of the same base:

- `$141C` shifts y left 5 and adds `#$57` -> 32 bytes per row, and `$142F`
  splits x into `x >> 3` for the byte and `x & 7` for a mask from the table at
  `$13D3` (`80 40 20 10 08 04 02 01`). That is **1 bit per cell**.
- `$0FAE` shifts y left 7 and adds `#$57` -> 128 bytes per row, with the mask
  pair `F0 0F` at `$0FD1` indexed by `x & 1`. That is **4 bits per cell**, and
  it is the same layout `MapDecoder` reads off a finished map disk.

Both cannot occupy `$5700` at once, so one must overwrite the other. This runs
the World Maker headlessly, stops the instant the land-mass phase finishes
(`$280A`, the sentinel target of the command loop at `$2158`), and renders
`$5700` **both ways**. Whichever reading produces recognizable continents is the
one that is live at that moment, and the answer is visual rather than statistical
- which matters here, because statistics on this project have repeatedly
supported conclusions that turned out to be wrong.

Requires vice-mcp (a VICE fork with MCP built in, not Homebrew VICE) and Pillow.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from rng_reference import wait_ready  # noqa: E402
from wm_trace import poke, dump, clear_checkpoints  # noqa: E402
from wm_config import arm, wait_hit  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = f"{ROOT}/d64/BLANKMAP2.D64"
GAME3_LOAD = 0x0800
ENTRY = 0x1E99
F7_WAIT_BRANCH = 0x1F8A          # BNE $1F7C -> NOP NOP
LANDMASS_DONE = 0x280A           # JMP target once the command table hits $FE

BASE = 0x5700
WIDTH, HEIGHT = 256, 400


def render_1bit(ram, path):
    """32 bytes per row, MSB first — the `$141C` / `$142F` reading."""
    from PIL import Image
    px = [255 if ram[y * 32 + (x >> 3)] & (0x80 >> (x & 7)) else 0
          for y in range(HEIGHT) for x in range(WIDTH)]
    img = Image.new("L", (WIDTH, HEIGHT))
    img.putdata(px)
    img.save(path)
    return sum(1 for v in px if v) / (WIDTH * HEIGHT)


def render_nibbles(ram, path):
    """128 bytes per row, high nibble first — the `$0FAE` / `$0FC3` reading."""
    from PIL import Image
    rows = min(HEIGHT, len(ram) // 128)
    px = [(ram[y * 128 + (x >> 1)] >> (0 if x & 1 else 4) & 0x0F) * 17
          for y in range(rows) for x in range(WIDTH)]
    img = Image.new("L", (WIDTH, rows))
    img.putdata(px)
    img.save(path)
    return rows


def main():
    outdir = sys.argv[1] if len(sys.argv) > 1 else f"{ROOT}/local"
    code = open(f"{ROOT}/local/game3.bin", "rb").read()

    clear_checkpoints()
    call("vice_execution_run")
    call("vice_machine_config_set", resources={"WarpMode": 1})
    call("vice_disk_detach", unit=8)
    time.sleep(1)
    call("vice_disk_attach", unit=8, path=DISK)
    call("vice_machine_reset", mode="hard")
    time.sleep(2)
    wait_ready()

    print(f"poking {len(code)} bytes at ${GAME3_LOAD:04X}", flush=True)
    poke(GAME3_LOAD, code)
    call("vice_memory_write", address=f"${F7_WAIT_BRANCH:04X}", data=[0xEA, 0xEA])

    num = arm(LANDMASS_DONE)
    call("vice_keyboard_type", text=f"SYS {ENTRY}\n")
    print(f"running to ${LANDMASS_DONE:04X} (land-mass phase complete)", flush=True)
    # Wait on the checkpoint's hit count. Polling `vice_ping` for "paused"
    # reports halts that never happened — see NOTES.md, harness gotchas.
    if not wait_hit(num, timeout=300):
        raise SystemExit("never reached the end of the land-mass phase")

    # The World Maker banks ROM out, so RAM under it must be read as "ram".
    ram = dump(BASE, 0xBEFF, bank="ram")
    open(os.path.join(outdir, "wm_5700.bin"), "wb").write(ram)

    one = os.path.join(outdir, "wm_5700_1bit.png")
    nib = os.path.join(outdir, "wm_5700_nibble.png")
    frac = render_1bit(ram, one)
    rows = render_nibbles(ram, nib)
    print(f"1-bit  ({WIDTH}x{HEIGHT}, 32 B/row): {frac * 100:5.2f}% set -> {one}")
    print(f"nibble ({WIDTH}x{rows}, 128 B/row):                   -> {nib}")
    print("\nLand should be a few percent of the map, not ~50%. Look at both "
          "images: one of them has coastlines.")

    clear_checkpoints()


if __name__ == "__main__":
    main()
