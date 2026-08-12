#!/usr/bin/env python3
"""Capture reference output for the World Maker's placement test (`$22F7`).

`$22F7` decides whether a landmass may sit at a position. It is easy to get
subtly wrong when transcribing — both of its scans are do-while loops that
exclude their far edge, and its bounds clamp asymmetrically — so it gets the
same treatment as the RNG: run the original and assert against it.

The mask it reads is built here from a handful of **rectangles** rather than
captured from a real run. It is not game data, so the fixture records the
rectangle list instead of 12,800 bytes and the Swift side rebuilds it exactly.

A uniformly random mask is useless for this: the cross samples roughly `6 * 2r`
cells, about 840 of them at radius 70, so *any* plausible density blocks every
position and the fixture cannot tell a correct port from one that always returns
false. A first attempt at 12.5% density produced 32 blocked cases and 0 clear.
Isolated blobs give a real mix, and resemble what the generator actually builds.

The driver must also set `$62 = 5`. That is the shift count `$22F7` uses to turn
a row number into an address, and the *phase* sets it at `$2130` — not the
routine. Without it the address arithmetic is garbage, which is invisible on an
all-zero or near-solid mask and wrong everywhere else.

Requires vice-mcp (a VICE fork with MCP built in, not Homebrew VICE).
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from rng_reference import wait_ready, read  # noqa: E402
from wm_trace import poke  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GAME3_LOAD = 0x0800
MASK_BASE = 0x5700
MASK_BYTES = 400 * 32
AREA_TEST = 0x22F7
DRIVER = 0xC000
OUT = 0xC300

# Land blobs as (x, y, width, height), all in the top half so the bottom half
# stays open for the large-radius cases.
BLOBS = [(30, 40, 20, 20), (150, 60, 40, 30), (200, 150, 10, 10)]

# (x, y, radius). Radius 70 and 10 are the two the generator actually uses; the
# rest probe the edges, the $FE clamp and the 256-row boundary.
CASES = [
    (128, 300, 70), (100, 350, 10), (60, 300, 10), (35, 150, 10),
    (40, 50, 10), (128, 60, 70), (170, 75, 10), (205, 155, 5),
    (30, 150, 120), (128, 255, 70), (128, 256, 70), (128, 257, 70),
    (0, 0, 10), (254, 398, 10), (128, 128, 1), (128, 128, 0),
    (245, 379, 10), (10, 255, 10),
]


def blob_mask(blobs):
    """Fill rectangles into a 32-byte-per-row mask; must match Swift exactly."""
    out = bytearray(MASK_BYTES)
    for bx, by, w, h in blobs:
        for y in range(by, by + h):
            for x in range(bx, bx + w):
                out[y * 32 + (x >> 3)] |= 0x80 >> (x & 7)
    return bytes(out)


def driver(x, y, radius):
    """Set $21/$22/$23/$24, call $22F7, store the carry flag as 0 or 1."""
    return [0x78,
            0xA9, 0x05, 0x85, 0x62,            # LDA #$05    : STA $62  (phase sets this)
            0xA9, radius, 0x85, 0x21,          # LDA #radius : STA $21
            0xA9, x, 0x85, 0x22,               # LDA #x      : STA $22
            0xA9, y & 0xFF, 0x85, 0x23,        # LDA #y.lo   : STA $23
            0xA9, y >> 8, 0x85, 0x24,          # LDA #y.hi   : STA $24
            0x20, AREA_TEST & 0xFF, AREA_TEST >> 8,
            0xA9, 0x00,                        # LDA #$00
            0x69, 0x00,                        # ADC #$00    -> A = carry
            0x8D, OUT & 0xFF, OUT >> 8,        # STA OUT
            0x58, 0x60]                        # CLI : RTS


def main():
    code = open(f"{ROOT}/local/game3.bin", "rb").read()
    call("vice_execution_run")
    call("vice_machine_config_set", resources={"WarpMode": 1})
    call("vice_machine_reset", mode="hard")
    time.sleep(2)
    wait_ready()
    poke(GAME3_LOAD, code)

    fixture = {"description": "Placement test $22F7 from the original 6502. The "
                              "mask is built from the blobs listed here, not "
                              "captured — no game data.",
               "blobs": [{"x": b[0], "y": b[1], "width": b[2], "height": b[3]}
                         for b in BLOBS],
               "cases": []}

    for _ in [0]:
        pattern = blob_mask(BLOBS)
        print(f"blob mask: "
              f"{sum(b.bit_count() for b in pattern) * 100 / (256 * 400):.2f}% set",
              flush=True)
        poke(MASK_BASE, pattern)
        for x, y, radius in CASES:
            call("vice_memory_fill", address=f"${OUT:04X}", length=1, value=0xEE)
            poke(DRIVER, bytes(driver(x, y, radius)))
            call("vice_keyboard_type", text=f"SYS {DRIVER}\n")
            time.sleep(0.35)
            carry = read(OUT, 1)[0]
            if carry not in (0, 1):
                raise SystemExit(f"driver did not run for {(x, y, radius)}")
            fixture["cases"].append({"x": x, "y": y, "radius": radius,
                                     "clear": carry == 0})
            print(f"  x={x:3d} y={y:3d} r={radius:2d}: "
                  f"{'clear' if carry == 0 else 'blocked'}", flush=True)

    out = (f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/"
           f"Fixtures/areatest_reference.json")
    with open(out, "w") as f:
        json.dump(fixture, f, indent=1)
    n = len(fixture["cases"])
    clear = sum(1 for c in fixture["cases"] if c["clear"])
    print(f"\nwrote {n} cases ({clear} clear, {n - clear} blocked) -> "
          f"{os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
