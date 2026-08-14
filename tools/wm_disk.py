#!/usr/bin/env python3
"""Run the whole World Maker in the interpreter and keep the disk it makes.

`sim_landmass.py` stops at the end of the land-mass phase because the next thing
the World Maker does is ask for a blank disk. With `vdrive.py` attached there is
a disk, so this picks up where that left off and lets the generator run: the mask
is unpacked into nibbles a band at a time, written out with direct block access,
and the phases after it get their turn.

The result is a map disk — the same thing the original produces on real hardware,
and the same thing `MapDecoder` reads. It is game data, so it is written wherever
you point `--out` and nothing goes in the repo.

    tools/wm_disk.py --seed 0x1234 --config 0 --out ~/tmp/generated.d64
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sim_landmass import machine, PHASE_DONE  # noqa: E402
from vdrive import VirtualDrive  # noqa: E402

# `$0E1C` is `JMP $0E1C`. The World Maker prints its last message, closes the
# drive and spins there for ever — that is what "finished" looks like.
DONE = 0x0E1C


def build(seed, config, budget, report=None):
    """Runs to the end of the land-mass phase, then onward with a drive."""
    cpu = machine(seed, config)
    _, steps = cpu.run_until({PHASE_DONE}, max_steps=40_000_000)
    cpu.step()

    drive = VirtualDrive()
    drive.attach(cpu)
    if report:
        report(f"  land-mass phase done in {steps:,} steps; drive attached")

    started = time.time()
    finished = False
    try:
        cpu.run_until({DONE}, max_steps=budget)
        finished = True
    except BaseException:                                   # noqa: BLE001
        pass
    if report:
        elapsed = time.time() - started
        report(f"  {'finished' if finished else 'ran out of budget'} "
               f"after {elapsed:.0f}s")
    return cpu, drive, finished


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", default="0x1234")
    parser.add_argument("--config", type=int, default=0)
    parser.add_argument("--budget", type=int, default=600_000_000)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    seed = int(args.seed, 0)
    print(f"seed ${seed:04X} config {args.config}", flush=True)
    cpu, drive, finished = build(seed, args.config, args.budget, report=print)

    tracks = sorted({t for t, _ in drive.written})
    print(f"  {len(drive.written)} sectors written across tracks "
          f"{tracks[0]}-{tracks[-1]}" if tracks else "  nothing written")
    if drive.unhandled:
        print(f"  unhandled DOS commands: {drive.unhandled[:5]}")
    print(f"  stopped at ${cpu.pc:04X}"
          + ("" if finished else " — not the finish spin at $0E1C"))

    with open(os.path.expanduser(args.out), "wb") as handle:
        handle.write(drive.blocks)
    print(f"wrote {os.path.expanduser(args.out)} ({len(drive.blocks):,} bytes)")


if __name__ == "__main__":
    main()
