#!/usr/bin/env python3
"""Run the World Maker headlessly and snapshot RAM between generation phases.

Pokes game3 into a bare C64 under vice-mcp, patches out its "press F7" wait,
and calls its real entry point with SYS. Checkpoints at the phase-message
printers pause the CPU so RAM can be dumped at each boundary.

Diffing consecutive snapshots localizes the map buffer and reveals which byte
values each phase writes — which is the terrain encoding.

The World Maker banks out ROM (`LDA #$35 / STA $01`), so RAM under ROM must be
read with bank="ram".
"""
import json
import os
import shutil
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from rng_reference import wait_ready  # noqa: E402

GAME3_LOAD = 0x0800
ENTRY = 0x1E99
F7_WAIT_BRANCH = 0x1F8A          # BNE $1F7C -> NOP NOP
CHUNK = 256
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DISK = f"{ROOT}/d64/BLANKMAP2.D64"

# Phase boundaries, in execution order. Each is the instruction that loads the
# status string for the *next* phase, so stopping there means the previous
# phase has just finished.
PHASES = [
    (0x2123, "after_init_before_landmass"),
    (0x0E26, "after_landmass"),
    (0x0E6A, "after_terrain"),
    (0x0E8A, "after_villages"),
]


def poke(addr, data):
    for i in range(0, len(data), CHUNK):
        call("vice_memory_write", address=f"${addr + i:04X}",
             data=list(data[i:i + CHUNK]))


def dump(lo=0x0000, hi=0xFFFF, bank="ram"):
    out = bytearray()
    a = lo
    while a <= hi:
        n = min(0x1000, hi - a + 1)
        r = call("vice_memory_read", address=f"${a:04X}", size=n, bank=bank,
                 encoding="hex")
        out += bytes.fromhex(r["data_hex"])
        a += n
    return bytes(out)


def clear_checkpoints():
    for cp in call("vice_checkpoint_list")["checkpoints"]:
        call("vice_checkpoint_delete", checkpoint_num=cp["checkpoint_num"])


def paused():
    return call("vice_ping")["execution"] == "paused"


def wait_paused(timeout=240):
    """Wait for a checkpoint to halt the CPU.

    Confirms the machine is actually *running* first. Right after
    `vice_execution_run` the emulator still reports "paused" for a moment, and
    polling straight away returns instantly — which silently produces several
    identical snapshots taken at the same instant.
    """
    end = time.time() + timeout
    while time.time() < end:
        if not paused():
            break
        time.sleep(0.2)
    else:
        raise SystemExit("machine never resumed")

    while time.time() < end:
        if paused():
            return True
        time.sleep(1)
    return False


def wait_finished(timeout=600):
    """Wait for the World Maker's completion screen.

    It ends by setting border and background to green ($05) and printing
    "THE NEW WORLD AWAITS!" (see $0DFF). Polling that is more reliable than
    guessing at a duration.
    """
    end = time.time() + timeout
    while time.time() < end:
        # The VIC returns 1s in the unused upper nibble, so green ($05) reads
        # back as $F5. Mask before comparing.
        raw = call("vice_memory_read", address="$D021", size=1,
                   encoding="hex")["data_hex"]
        if int(raw, 16) & 0x0F == 0x05:
            return True
        time.sleep(2)
    return False


def run_full(code, outdir):
    """Generate a complete world with no checkpoints, so every phase finishes.

    Stopping at phase boundaries captures the disk before the terrain pass is
    written back — the pipeline runs twice and only writes after each complete
    pass — so a checkpointed run yields land and ocean but no terrain.
    """
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
    call("vice_keyboard_type", text=f"SYS {ENTRY}\n")
    print("generating (no checkpoints; this runs the whole pipeline)", flush=True)

    if not wait_finished():
        print("TIMEOUT: never reached the completion screen", flush=True)
        return None
    time.sleep(3)                       # let the last write flush
    dest = os.path.join(outdir, "wm_complete.d64")
    shutil.copyfile(DISK, dest)
    print(f"complete -> {dest}", flush=True)
    return dest


def main():
    game3 = sys.argv[1] if len(sys.argv) > 1 else "local/game3.bin"
    outdir = sys.argv[2] if len(sys.argv) > 2 else "."
    code = open(game3, "rb").read()

    if "--full" in sys.argv:
        run_full(code, outdir)
        return

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

    back = dump(GAME3_LOAD, GAME3_LOAD + len(code) - 1, bank="ram")
    patched = bytearray(code)
    patched[F7_WAIT_BRANCH - GAME3_LOAD:F7_WAIT_BRANCH - GAME3_LOAD + 2] = b"\xEA\xEA"
    if back != bytes(patched):
        raise SystemExit("game3 write verification failed")
    print("game3 loaded and F7 wait patched out", flush=True)

    snapshots = {}
    for addr, name in PHASES:
        clear_checkpoints()
        call("vice_checkpoint_add", start=f"${addr:04X}", exec=True, stop=True)
        if not snapshots:
            call("vice_keyboard_type", text=f"SYS {ENTRY}\n")
        else:
            call("vice_execution_run")
        if not wait_paused():
            print(f"TIMEOUT waiting for {name} (${addr:04X})", flush=True)
            break
        # The map is assembled on disk, not in RAM — 104 KB will not fit in
        # 64 KB, which is why generation takes 18 minutes. Snapshot the disk
        # image, not memory.
        ram = dump()
        path = os.path.join(outdir, f"wm_{name}.bin")
        open(path, "wb").write(ram)
        disk = os.path.join(outdir, f"wm_{name}.d64")
        shutil.copyfile(DISK, disk)
        snapshots[name] = {"ram": path, "disk": disk}
        pc = call("vice_registers_get")["PC"]
        print(f"{name}: stopped at ${pc:04X}, dumped {len(ram)} bytes -> {path}",
              flush=True)

    clear_checkpoints()
    with open(os.path.join(outdir, "wm_snapshots.json"), "w") as f:
        json.dump(snapshots, f, indent=1)
    print("done", flush=True)


if __name__ == "__main__":
    main()
