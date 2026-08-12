#!/usr/bin/env python3
"""Capture reference output for the World Maker's bounded draws.

Executes the ORIGINAL `$22B4` (8-bit) and `$247B` (16-bit) rejection samplers on
an emulated 6502 and records what they return, so the Swift transcription can be
asserted against them. Same approach as `rng_reference.py`.

Both routines are self-modifying — `$22B4` writes its bounds into the operand
bytes of its own `CMP` instructions — so the whole of `game3` is poked into RAM
rather than just the routine, and the code is executed in place.

Two hazards, both real:
  - The KERNAL uses `$CC`-`$CF` for cursor blink, which is exactly the LFSR's
    zero page. The drivers run under `SEI`.
  - `$247B` only short-circuits when its bounds are *equal*; an inverted range
    spins forever. No inverted range is included in the sweep, and none should
    be — it would hang the emulator, not fail the test.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from rng_reference import wait_ready, read  # noqa: E402
from wm_trace import poke  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME3_LOAD = 0x0800
BYTE_RANGE = 0x22B4
WORD_RANGE = 0x247B
DRIVER = 0xC000
LO_TBL, HI_TBL, OUT = 0xC200, 0xC280, 0xC300

SEEDS = [0x0001, 0x1234, 0xFFFF, 0xA55A]

# lo, hi pairs. `lo >= hi` is safe for the 8-bit routine (it returns lo) and is
# included because that guard is easy to get wrong when transcribing.
BYTE_CASES = [(0, 1), (0, 255), (10, 20), (70, 184), (5, 5), (200, 100),
              (1, 2), (128, 129), (0, 128), (250, 255)]

# Realistic placement bounds: `size .. 254 - size` in x, `size + 2 .. 389 - size`
# in y, for the radius-70 and radius-10 landmasses, plus config 2's clamp.
WORD_CASES = [(72, 319), (12, 379), (110, 220), (100, 100), (0, 400), (1, 511)]


def byte_driver(seed):
    """SEI; seed; for each case call $22B4 with A=lo, X=hi; store A."""
    n = len(BYTE_CASES)
    pre = [0x78,
           0xA9, seed >> 8, 0x85, 0xCD,
           0xA9, seed & 0xFF, 0x85, 0xCF,
           0xA0, 0x00]
    loop = [0xBE, HI_TBL & 0xFF, HI_TBL >> 8,        # LDX HI_TBL,Y
            0xB9, LO_TBL & 0xFF, LO_TBL >> 8,        # LDA LO_TBL,Y
            0x20, BYTE_RANGE & 0xFF, BYTE_RANGE >> 8,
            0x99, OUT & 0xFF, OUT >> 8,              # STA OUT,Y
            0xC8,
            0xC0, n]
    return pre + loop + [0xD0, -(len(loop) + 2) & 0xFF, 0x58, 0x60]


def word_driver(seed, lo, hi):
    """SEI; seed; set $06/$03 = lo and $07/$53 = hi; call $247B; store $23/$24."""
    return [0x78,
            0xA9, seed >> 8, 0x85, 0xCD,
            0xA9, seed & 0xFF, 0x85, 0xCF,
            0xA9, lo & 0xFF, 0x85, 0x06,
            0xA9, lo >> 8, 0x85, 0x03,
            0xA9, hi & 0xFF, 0x85, 0x07,
            0xA9, hi >> 8, 0x85, 0x53,
            0x20, WORD_RANGE & 0xFF, WORD_RANGE >> 8,
            0xA5, 0x23, 0x8D, OUT & 0xFF, OUT >> 8,
            0xA5, 0x24, 0x8D, (OUT + 1) & 0xFF, (OUT + 1) >> 8,
            0x58, 0x60]


def run(driver_code, out_len):
    call("vice_memory_fill", address=f"${OUT:04X}", length=out_len + 2, value=0)
    poke(DRIVER, bytes(driver_code))
    call("vice_keyboard_type", text=f"SYS {DRIVER}\n")
    import time
    time.sleep(0.6)
    return read(OUT, out_len)


def main():
    code = open(f"{ROOT}/local/game3.bin", "rb").read()
    call("vice_execution_run")
    call("vice_machine_config_set", resources={"WarpMode": 1})
    call("vice_machine_reset", mode="hard")
    import time
    time.sleep(2)
    wait_ready()
    poke(GAME3_LOAD, code)

    fixture = {"description": "Bounded draws from the World Maker's LFSR, "
                              "captured from the original 6502 ($22B4 and $247B).",
               "byteCases": [], "wordCases": []}

    for seed in SEEDS:
        poke(LO_TBL, bytes(lo for lo, _ in BYTE_CASES))
        poke(HI_TBL, bytes(hi for _, hi in BYTE_CASES))
        got = run(byte_driver(seed), len(BYTE_CASES))
        for (lo, hi), v in zip(BYTE_CASES, got):
            fixture["byteCases"].append({"seed": seed, "lo": lo, "hi": hi, "value": v})
        print(f"  8-bit  seed ${seed:04X}: {got}", flush=True)

    for seed in SEEDS:
        for lo, hi in WORD_CASES:
            b = run(word_driver(seed, lo, hi), 2)
            v = b[0] | b[1] << 8
            fixture["wordCases"].append({"seed": seed, "lo": lo, "hi": hi, "value": v})
        vals = [c["value"] for c in fixture["wordCases"] if c["seed"] == seed]
        print(f"  16-bit seed ${seed:04X}: {vals}", flush=True)

    out = (f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/"
           f"Fixtures/randrange_reference.json")
    with open(out, "w") as f:
        json.dump(fixture, f, indent=1)
    print(f"\nwrote {len(fixture['byteCases'])} byte + {len(fixture['wordCases'])} "
          f"word cases -> {os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
