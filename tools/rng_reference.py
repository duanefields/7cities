#!/usr/bin/env python3
"""Generate RNG reference fixtures by executing the ORIGINAL 6502 code in VICE.

Loads the World Maker's LFSR ($0AE2-$0B0F) into a freshly reset C64 along with
a small driver, then transfers control with SYS so the original routine really
executes on an emulated 6502. Results are captured to a buffer and read back.

Two things this works around, both learned the hard way:
  - The KERNAL uses $CC-$CF for cursor blink, so its IRQ corrupts the LFSR
    state between calls. The driver runs under SEI.
  - Setting PC via the debugger and resuming does not stick; control has to be
    transferred by the machine itself (SYS), not by poking registers.
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402

RNG_START = 0x0AE2
RNG_RTS = 0x0B0F
GAME3_LOAD = 0x0800
DRIVER = 0xC000
BUF_A, BUF_CD, BUF_CF = 0xC100, 0xC140, 0xC180
SEEDS = [(0x00, 0x01), (0x12, 0x34), (0xFF, 0xFF), (0xA5, 0x5A), (0x01, 0x00)]
COUNT = 0x40


def rng_bytes(path):
    data = open(path, "rb").read()
    return list(data[RNG_START - GAME3_LOAD:RNG_RTS + 1 - GAME3_LOAD])


def driver(hi, lo):
    """SEI; seed $CD/$CF; call the LFSR COUNT times capturing A, $CD, $CF."""
    pre = [0x78,                     # SEI
           0xA9, hi, 0x85, 0xCD,     # LDA #hi : STA $CD
           0xA9, lo, 0x85, 0xCF,     # LDA #lo : STA $CF
           0xA0, 0x00]               # LDY #$00
    loop = [0x20, RNG_START & 0xFF, RNG_START >> 8,      # JSR rng
            0x99, BUF_A & 0xFF, BUF_A >> 8,              # STA BUF_A,Y
            0xA5, 0xCD, 0x99, BUF_CD & 0xFF, BUF_CD >> 8,
            0xA5, 0xCF, 0x99, BUF_CF & 0xFF, BUF_CF >> 8,
            0xC8,                                        # INY
            0xC0, COUNT]                                 # CPY #COUNT
    back = -(len(loop) + 2)                              # BNE loop
    return pre + loop + [0xD0, back & 0xFF, 0x58, 0x60]  # BNE : CLI : RTS


def read(addr, n):
    r = call("vice_memory_read", address=f"${addr:04X}", size=n, encoding="hex")
    return list(bytes.fromhex(r["data_hex"]))


READY = [18, 5, 1, 4, 25, 46]   # "READY." in screen codes


def wait_ready(timeout=30):
    """Block until BASIC shows its READY prompt; typing earlier is dropped."""
    end = time.time() + timeout
    while time.time() < end:
        screen = read(0x0400, 1000)
        for i in range(len(screen) - len(READY)):
            if screen[i:i + len(READY)] == READY:
                return True
        time.sleep(0.5)
    raise SystemExit("BASIC never reached READY")


def wait_buffer(addr, n, timeout=30):
    """Block until the driver has written something into its result buffer."""
    end = time.time() + timeout
    while time.time() < end:
        vals = read(addr, n)
        if any(v != 0 for v in vals):
            return vals
        time.sleep(0.5)
    return read(addr, n)


def main():
    game3 = sys.argv[1] if len(sys.argv) > 1 else "local/game3.bin"
    dest = sys.argv[2] if len(sys.argv) > 2 else "rng_reference.json"
    code = rng_bytes(game3)

    # A leftover checkpoint leaves the CPU paused, so the machine never boots
    # and every later step silently does nothing. Clear them first.
    for cp in call("vice_checkpoint_list")["checkpoints"]:
        call("vice_checkpoint_delete", checkpoint_num=cp["checkpoint_num"])
    call("vice_execution_run")

    out = {"source": "original 6502 executed in VICE",
           "routine": f"${RNG_START:04X}-${RNG_RTS:04X}",
           "state": "$CD high, $CF low", "sequences": []}

    for hi, lo in SEEDS:
        call("vice_machine_reset", mode="hard")
        wait_ready()
        call("vice_memory_write", address=f"${RNG_START:04X}", data=code)
        call("vice_memory_write", address=f"${DRIVER:04X}", data=driver(hi, lo))
        if read(RNG_START, len(code)) != code:
            raise SystemExit("RNG write verification failed")
        call("vice_memory_fill", start=f"${BUF_A:04X}",
             end=f"${BUF_CF + COUNT - 1:04X}", pattern=[0])
        call("vice_keyboard_type", text=f"SYS {DRIVER}\n")
        vals = wait_buffer(BUF_A, COUNT)
        cds = read(BUF_CD, COUNT)
        cfs = read(BUF_CF, COUNT)
        if all(v == 0 for v in vals):
            raise SystemExit(f"driver produced nothing for seed ${hi:02X}{lo:02X}")
        out["sequences"].append({
            "seed_cd": hi, "seed_cf": lo, "values": vals,
            "states": [[c, f] for c, f in zip(cds, cfs)]})
        print(f"seed ${hi:02X}{lo:02X}: " +
              " ".join(f"{v:02X}" for v in vals[:16]), flush=True)

    with open(dest, "w") as f:
        json.dump(out, f, indent=1)
    print("wrote", dest)


if __name__ == "__main__":
    main()
