#!/usr/bin/env python3
"""Capture the positions the placement loop chooses, from the original 6502.

The coastline walker is not ported yet, so there is no way to compare a whole
land mask. But the placement loop can be checked on its own: `$1B5F` is called
exactly once per **accepted** landmass, and at that moment zero page holds the
chosen position and everything that went into it. Breaking there and recording
the sequence gives an oracle for the placement loop that needs no walker at all.

It is a demanding oracle, because a position only comes out right if everything
upstream did:

- the retry loop discarded the same rejected candidates (`$22F7` at `$222C`),
- the paired-placement retest at `$2231` accepted or rejected the same pairs,
- and every draw consumed the same number of LFSR steps, including two that are
  easy to miss. `$4E` is drawn at `$2186` **before** the paired flag is tested
  and then overwritten with `$FF` when the command is not paired, and `$B1`/`$B2`
  take a coin flip at `$2193` that is likewise overwritten for islands. Both
  advance the generator whether or not their results are used, so a port that
  skips them desynchronizes every later draw.

`$1B5F` only fires for the command-table stage; the second wave at `$280A` uses
`$194A` instead, so this isolates exactly the loop being ported.

Requires vice-mcp (a VICE fork with MCP built in, not Homebrew VICE).
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from wm_trace import dump, clear_checkpoints  # noqa: E402
from wm_config import boot, ENTRY, PHASE_DONE  # noqa: E402
from wm_deterministic import apply_patches  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTER_LANDMASS = 0x1B5F

SEEDS = [0x1234, 0xBEEF, 0x0001]
CONFIGS = [0, 1, 2]

# Zero page read at each hit. $21/$B0 are the radius, $22/$23/$24 the position,
# $43 the command's flags, $54 its size class, $4E the paired x offset.
SLOTS = {"radius": 0x21, "sizeClass": 0x54, "flags": 0x43, "pairOffset": 0x4E,
         "x": 0x22, "yLow": 0x23, "yHigh": 0x24, "b0": 0xB0}


def hits():
    return {cp["checkpoint_num"]: cp["hit_count"]
            for cp in call("vice_checkpoint_list")["checkpoints"]}


def wait_change(before, timeout=300):
    """Wait for any checkpoint's hit count to rise; return its number."""
    end = time.time() + timeout
    while time.time() < end:
        now = hits()
        for num, count in now.items():
            if count > before.get(num, 0):
                return num, now
        time.sleep(0.2)
    return None, hits()


def capture(code, seed, config):
    boot(code)
    apply_patches(seed, config)
    clear_checkpoints()
    reg = call("vice_checkpoint_add", start=f"${REGISTER_LANDMASS:04X}",
               exec=True, stop=True)["checkpoint_num"]
    end = call("vice_checkpoint_add", start=f"${PHASE_DONE:04X}",
               exec=True, stop=True)["checkpoint_num"]

    before = hits()
    call("vice_keyboard_type", text=f"SYS {ENTRY}\n")
    placements = []
    while True:
        num, before = wait_change(before)
        if num is None:
            raise SystemExit(f"seed ${seed:04X} config {config}: stalled")
        if num == end:
            break
        zp = dump(0x00, 0xFF, bank="ram")
        placements.append({k: zp[a] for k, a in SLOTS.items()})
        placements[-1]["y"] = zp[0x23] | zp[0x24] << 8
        call("vice_execution_run")
    clear_checkpoints()
    return placements


def main():
    code = open(f"{ROOT}/local/game3.bin", "rb").read()
    cases = []
    for seed in SEEDS:
        for config in CONFIGS:
            placements = capture(code, seed, config)
            cases.append({"seed": seed, "config": config,
                          "placements": placements})
            summary = ", ".join(f"({p['x']},{p['y']})r{p['radius']}"
                                for p in placements)
            print(f"  seed ${seed:04X} config {config}: {len(placements)} "
                  f"placements  {summary}", flush=True)

    out = (f"{ROOT}/SevenCitiesCore/Tests/SevenCitiesCoreTests/"
           f"Fixtures/placement_reference.json")
    with open(out, "w") as f:
        json.dump({"description": "Positions chosen by the land-mass placement "
                                  "loop, read at $1B5F in the original 6502. "
                                  "Coordinates and radii only — no map data.",
                   "cases": cases}, f, indent=1)
    total = sum(len(c["placements"]) for c in cases)
    print(f"\nwrote {len(cases)} cases, {total} placements -> "
          f"{os.path.relpath(out, ROOT)}")


if __name__ == "__main__":
    main()
