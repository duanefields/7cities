#!/usr/bin/env python3
"""Force each of the three world configurations and check what gets built.

The land-mass phase picks a configuration at `$2146`-`$2157`: a random byte,
divided by `$5A` (90) to give 0, 1 or 2, kept in `$57` and multiplied by 7 to
index the command table at `$2286`. Reading that table as sequences of 3-byte
`(size class, flags, count)` commands terminated by `$FE` predicts:

    0 -> 2 continents + 2 islands
    1 -> 1 continent (paired-placement flag) + 2 islands
    2 -> 1 continent + 6 islands, islands clamped to a latitude band

which is a falsifiable prediction rather than a plausible story. So break at
`$2150` (`STA $57`, immediately after the divide), overwrite A with the chosen
configuration — that sets both `$57` and, via the multiply at `$2154`, the table
index — and count what appears in the land mask at `$5700`.

Counting is by flood fill on the 1-bit mask, with continents and islands
separated by area: radius 70 versus radius 10 is a 49x difference, so no
threshold tuning is needed.

Requires vice-mcp (a VICE fork with MCP built in, not Homebrew VICE) and Pillow.
"""
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from rng_reference import wait_ready  # noqa: E402
from wm_trace import poke, dump, clear_checkpoints  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = f"{ROOT}/d64/BLANKMAP2.D64"
GAME3_LOAD = 0x0800
ENTRY = 0x1E99
F7_WAIT_BRANCH = 0x1F8A
SELECTOR = 0x2146                # JSR $0AE2 .. JSR $0A6E, the config draw
# The $FE sentinel jumps here, which ends the **command table stage** — not the
# phase. $280A then draws a further random(2..8) small islands (random(8..13) for
# configuration 2) and places them at radius 3, ending at $2894. Stopping at
# $280A is right for checking the command table and wrong for anything that wants
# the phase's actual output.
TABLE_STAGE_DONE = 0x280A
PHASE_DONE = 0x2894
BASE = 0x5700
WIDTH, HEIGHT = 256, 400
OUTDIR = f"{ROOT}/local"


def arm(address):
    """Set a single execution checkpoint and return its number."""
    clear_checkpoints()
    r = call("vice_checkpoint_add", start=f"${address:04X}", exec=True, stop=True)
    return r["checkpoint_num"]


def wait_hit(num, timeout=300):
    """Wait for checkpoint `num` to register a hit.

    **Poll `hit_count`, not `vice_ping` and not the PC.** Neither of the
    obvious signals works here:

    - `vice_ping` reports "paused" for reasons unrelated to checkpoints, so a
      ping loop reports a halt that never happened and RAM gets read mid-phase.
      Runs were misread this way as stopping at `$22DB`, `$2385` and `$236C` —
      all inside the placement loop, none of them a checkpoint.
    - The PC is readable while the CPU runs and simply never equals the target
      when sampled, so waiting for it to match spins until the timeout.

    `hit_count` is unambiguous: it is zero until the checkpoint fires and
    nonzero afterwards.
    """
    end = time.time() + timeout
    while time.time() < end:
        for cp in call("vice_checkpoint_list")["checkpoints"]:
            if cp["checkpoint_num"] == num and cp["hit_count"] > 0:
                return True
        time.sleep(0.3)
    return False


def mask_bits(ram):
    grid = bytearray(WIDTH * HEIGHT)
    for y in range(HEIGHT):
        row = y * 32
        for x in range(WIDTH):
            if ram[row + (x >> 3)] & (0x80 >> (x & 7)):
                grid[y * WIDTH + x] = 1
    return grid


def save_png(grid, path):
    from PIL import Image
    img = Image.new("L", (WIDTH, HEIGHT))
    img.putdata([255 if v else 0 for v in grid])
    img.save(path)


def blobs(grid):
    """Flood-fill connected land, returning areas largest first."""
    seen = bytearray(WIDTH * HEIGHT)
    areas = []
    for start in range(WIDTH * HEIGHT):
        if not grid[start] or seen[start]:
            continue
        stack, n = [start], 0
        seen[start] = 1
        while stack:
            i = stack.pop()
            n += 1
            x, y = i % WIDTH, i // WIDTH
            for nx, ny in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if 0 <= nx < WIDTH and 0 <= ny < HEIGHT:
                    j = ny * WIDTH + nx
                    if grid[j] and not seen[j]:
                        seen[j] = 1
                        stack.append(j)
        areas.append(n)
    return sorted(areas, reverse=True)


def boot(code):
    """Reset to a BASIC prompt and load `game3`, recovering a wedged machine.

    `game3` runs with ROM banked out (`$01 = $35`). If a run ends with the CPU
    halted inside it — a checkpoint left armed, a harness crash — the next reset
    has no ROM to reset *into*: `$FFFC` reads RAM, and VICE answers "Machine
    power cycled" while the PC never moves. That has wedged the emulator twice in
    this project, once beyond recovery.

    Pausing and restoring `$01` to `$37` **before** resetting fixes it, so do that
    every time rather than only after something has already gone wrong.
    """
    clear_checkpoints()
    call("vice_execution_pause")
    call("vice_memory_write", address="$0001", data=[0x37])
    call("vice_machine_reset", mode="hard")
    call("vice_execution_run")
    time.sleep(1)
    call("vice_machine_config_set", resources={"WarpMode": 1})
    call("vice_disk_detach", unit=8)
    time.sleep(1)
    call("vice_disk_attach", unit=8, path=DISK)
    call("vice_machine_reset", mode="hard")
    time.sleep(2)
    wait_ready()
    poke(GAME3_LOAD, code)
    call("vice_memory_write", address=f"${F7_WAIT_BRANCH:04X}", data=[0xEA, 0xEA])


def trial(code, config):
    """Force one configuration by **patching the selector**, not by poking A.

    Setting A at a checkpoint on `$2150` looked like the surgical option and is
    not: `$57` came back as 1 no matter what was written, because the phase is
    entered more than once and the checkpoint caught a later pass. Overwriting
    the ten bytes that compute the index removes the timing question entirely —
    the configuration is then a constant no matter when the code runs.

        $2146  JSR $0AE2      random byte        ->  LDA #config
        $2149  LDY #$00                          ->  NOP ...
        $214B  LDX #$5A       divisor
        $214D  JSR $0A6E      /90 -> 0..2
        $2150  STA $57        (kept — now stores the constant)
    """
    boot(code)
    patch = bytes([0xA9, config]) + b"\xEA" * 8      # LDA #config, then NOPs
    call("vice_memory_write", address=f"${SELECTOR:04X}", data=list(patch))
    back = dump(SELECTOR, SELECTOR + len(patch) - 1, bank="ram")
    if back != patch:
        print(f"  config {config}: selector patch did not stick")
        return None

    num = arm(TABLE_STAGE_DONE)
    call("vice_keyboard_type", text=f"SYS {ENTRY}\n")
    if not wait_hit(num):
        pc = call("vice_registers_get")["PC"]
        print(f"  config {config}: phase never finished (PC ${pc:04X})")
        return None

    seq = dump(0x57, 0x57, bank="ram")[0]
    if seq != config:
        print(f"  config {config}: $57 reads {seq}, patch was bypassed")
        return None

    ram = dump(BASE, BASE + HEIGHT * 32 - 1, bank="ram")
    grid = mask_bits(ram)
    save_png(grid, os.path.join(OUTDIR, f"wm_config{config}.png"))
    areas = blobs(grid)
    big = [a for a in areas if a > 2000]
    small = [a for a in areas if 40 < a <= 2000]
    print(f"  config {config}: {len(big)} continent(s), {len(small)} island(s)"
          f"   areas={areas[:10]}")
    return len(big), len(small)


def main():
    code = open(f"{ROOT}/local/game3.bin", "rb").read()
    expect = {0: (2, 2), 1: (1, 2), 2: (1, 6)}
    print("configuration -> land masses built")
    ok = True
    for config in (0, 1, 2):
        got = trial(code, config)
        if got is None:
            ok = False
            continue
        want = expect[config]
        verdict = "matches prediction" if got == want else f"PREDICTED {want}"
        print(f"           expected {want}, got {got}: {verdict}")
        ok &= got == want
    clear_checkpoints()
    print("\nall three configurations match" if ok else "\nmismatch — see above")


if __name__ == "__main__":
    main()
