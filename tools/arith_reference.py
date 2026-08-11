#!/usr/bin/env python3
"""Capture reference output for the World Maker's multiply and divide helpers.

Same approach as rng_reference.py: load the original 6502 routines into a bare
C64 under vice-mcp, drive them with a poked-in loop, and read the results back.

Each sweep runs the routine over all 256 values of one input with the other
inputs fixed, so a single run covers 256 cases.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from rng_reference import wait_ready, wait_buffer, read  # noqa: E402

GAME3_LOAD = 0x0800
MUL, MUL_END = 0x0A51, 0x0A6D
DIV, DIV_END = 0x0A6E, 0x0A86
DRIVER = 0xC000
BUF1, BUF2 = 0xC100, 0xC200
DONE = 0xC300          # driver writes $A5 here when finished
COUNTER = 0xFB

MUL_MULTIPLIERS = [0, 1, 2, 3, 7, 10, 90, 255]
DIV_CASES = [(0, 90), (0, 7), (0, 3), (0, 255), (1, 90), (3, 200), (0, 1)]


def slice_of(data, start, end):
    return list(data[start - GAME3_LOAD:end + 1 - GAME3_LOAD])


def mul_driver(multiplier):
    """for i in 0..255: (low, high) = i * multiplier"""
    return [
        0x78,                                       # SEI
        0xA9, 0x00, 0x85, COUNTER,                  # LDA #0 : STA counter
        # loop:
        0xA5, COUNTER,                              # LDA counter
        0xA0, multiplier,                           # LDY #multiplier
        0x20, MUL & 0xFF, MUL >> 8,                 # JSR multiply
        0xA6, COUNTER,                              # LDX counter
        0x9D, BUF1 & 0xFF, BUF1 >> 8,               # STA BUF1,X   (low)
        0x98,                                       # TYA          (high)
        0x9D, BUF2 & 0xFF, BUF2 >> 8,               # STA BUF2,X
        0xE6, COUNTER,                              # INC counter
        0xD0, (256 - 20) & 0xFF,                    # BNE loop
        0xA9, 0xA5, 0x8D, DONE & 0xFF, DONE >> 8,   # LDA #$A5 : STA DONE
        0x58, 0x60,                                 # CLI : RTS
    ]


def div_driver(high, divisor):
    """for i in 0..255: (quotient, remainder) = (high:i) / divisor"""
    return [
        0x78,
        0xA9, 0x00, 0x85, COUNTER,
        # loop:
        0xA5, COUNTER,                              # LDA counter  (dividend low)
        0xA0, high,                                 # LDY #high
        0xA2, divisor,                              # LDX #divisor
        0x20, DIV & 0xFF, DIV >> 8,                 # JSR divide
        0xA6, COUNTER,                              # LDX counter
        0x9D, BUF1 & 0xFF, BUF1 >> 8,               # STA BUF1,X   (quotient)
        0x98,                                       # TYA          (remainder)
        0x9D, BUF2 & 0xFF, BUF2 >> 8,               # STA BUF2,X
        0xE6, COUNTER,
        0xD0, (256 - 22) & 0xFF,                    # BNE loop
        0xA9, 0xA5, 0x8D, DONE & 0xFF, DONE >> 8,   # LDA #$A5 : STA DONE
        0x58, 0x60,
    ]


def run_sweep(code_blocks, drv):
    # Fail with something readable if the emulator died mid-run, rather than a
    # urllib connection-refused traceback fifteen frames deep.
    try:
        if call("vice_ping").get("status") != "ok":
            raise SystemExit("VICE is not responding")
    except OSError as err:
        raise SystemExit(f"VICE is not reachable: {err}") from err

    call("vice_machine_reset", mode="hard")
    time.sleep(1)          # don't hammer power-cycles back to back
    wait_ready()
    for addr, blob in code_blocks:
        call("vice_memory_write", address=f"${addr:04X}", data=blob)
    call("vice_memory_write", address=f"${DRIVER:04X}", data=drv)
    call("vice_memory_fill", start=f"${BUF1:04X}", end=f"${DONE:04X}",
         pattern=[0])
    call("vice_keyboard_type", text=f"SYS {DRIVER}\n")
    if wait_buffer(DONE, 1)[0] != 0xA5:
        raise SystemExit("driver did not signal completion")
    return read(BUF1, 256), read(BUF2, 256)


def main():
    game3 = sys.argv[1] if len(sys.argv) > 1 else "local/game3.bin"
    dest = sys.argv[2] if len(sys.argv) > 2 else "arith_reference.json"
    data = open(game3, "rb").read()
    mul_code = (MUL, slice_of(data, MUL, MUL_END))
    div_code = (DIV, slice_of(data, DIV, DIV_END))

    for cp in call("vice_checkpoint_list")["checkpoints"]:
        call("vice_checkpoint_delete", checkpoint_num=cp["checkpoint_num"])
    call("vice_execution_run")

    out = {"source": "original 6502 executed in VICE",
           "multiply": [], "divide": []}

    for m in MUL_MULTIPLIERS:
        lows, highs = run_sweep([mul_code], mul_driver(m))
        out["multiply"].append({"multiplier": m, "low": lows, "high": highs})
        print(f"mul x{m:<3d}: " + " ".join(f"{v:02X}" for v in lows[:8]), flush=True)

    for high, divisor in DIV_CASES:
        qs, rs = run_sweep([div_code], div_driver(high, divisor))
        out["divide"].append({"high": high, "divisor": divisor,
                              "quotient": qs, "remainder": rs})
        print(f"div high={high} by {divisor:<3d}: " +
              " ".join(f"{v:02X}" for v in qs[:8]), flush=True)

    with open(dest, "w") as f:
        json.dump(out, f, indent=1)
    print("wrote", dest)


if __name__ == "__main__":
    main()
