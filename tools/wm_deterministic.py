#!/usr/bin/env python3
"""Make the World Maker's land-mass phase reproducible, and prove that it is.

World generation was never reproducible on real hardware. The LFSR is seeded
from SID oscillator 3 (`$20CB`), and the raster IRQ at `$23FC` keeps stirring
the high byte with a live oscillator read on **every interrupt**, so the same
machine with the same disk produced a different world each run. That is fine for
players and useless for porting: a port cannot be checked against output that
never repeats.

Three patches remove every source of variation from the land-mass phase:

    $20CB  LDA $D41B / STA $CD / LDA $D41B / STA $CF   ->  load a constant seed
    $2406  LDA $D41B / ADC $CD / STA $CD               ->  NOPs (kill the stir)
    $2146  JSR $0AE2 .. JSR $0A6E                      ->  LDA #config

`$0A49` also touches hardware (`LDA $D012`) but is a raster sync — it spins
until scanline `$FE` and always returns the same value — so it does not need
patching. Those are the only hardware reads in `game3`.

With all three applied the phase becomes a pure function of `(seed, config)`,
and `$5700` can be dumped as a 12,800-byte fixture the Swift port must
reproduce bit for bit.

Note the IRQ handler is **not** in `local/game3.disasm.lst`: it is reached
through the IRQ vector, never by `JSR` or `JMP`, so the recursive-descent
disassembler never walks it. Its bytes are verified against the file here
instead.

Requires vice-mcp (a VICE fork with MCP built in, not Homebrew VICE).
"""
import hashlib
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from v import call  # noqa: E402
from wm_trace import dump  # noqa: E402
from wm_config import (boot, arm, wait_hit, clear_checkpoints,  # noqa: E402
                       TABLE_STAGE_DONE, PHASE_DONE, ENTRY)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = 0x5700
MASK_BYTES = 400 * 32

SEED_SITE = 0x20CB
STIR_SITE = 0x2406
SELECTOR = 0x2146

# What must be at each site before it is overwritten. Patching without checking
# is how a harness silently starts measuring the wrong thing.
EXPECTED = {
    SEED_SITE: bytes([0xAD, 0x1B, 0xD4, 0x85, 0xCD, 0xAD, 0x1B, 0xD4, 0x85, 0xCF]),
    STIR_SITE: bytes([0xAD, 0x1B, 0xD4, 0x65, 0xCD, 0x85, 0xCD]),
    SELECTOR: bytes([0x20, 0xE2, 0x0A, 0xA0, 0x00, 0xA2, 0x5A, 0x20, 0x6E, 0x0A]),
}


def patches(seed, config):
    """The three patches, as {address: bytes}.

    `$CD` is the seed's high byte and `$CF` its low byte — the LFSR shifts
    `ROL $CF` then `ROL $CD`.
    """
    hi, lo = (seed >> 8) & 0xFF, seed & 0xFF
    return {
        SEED_SITE: bytes([0xA9, hi, 0x85, 0xCD, 0xA9, lo, 0x85, 0xCF, 0xEA, 0xEA]),
        STIR_SITE: bytes([0xEA] * 7),
        SELECTOR: bytes([0xA9, config]) + b"\xEA" * 8,
    }


def apply_patches(seed, config):
    for addr, want in EXPECTED.items():
        got = dump(addr, addr + len(want) - 1, bank="ram")
        if got != want:
            raise SystemExit(f"${addr:04X}: expected {want.hex()}, found {got.hex()}")
    for addr, data in patches(seed, config).items():
        call("vice_memory_write", address=f"${addr:04X}", data=list(data))
        if dump(addr, addr + len(data) - 1, bank="ram") != data:
            raise SystemExit(f"${addr:04X}: patch did not stick")


def land_mask(code, seed, config):
    """Run the phase for one (seed, config), capturing **both** stop points.

    Returns `{"tableStage": ..., "phaseEnd": ...}`. Both matter: the table stage
    is the incremental milestone a port can hit first, and the phase end is the
    real output. One run yields both — stop at `$280A`, dump, then continue to
    `$2894` and dump again.
    """
    boot(code)
    apply_patches(seed, config)

    num = arm(TABLE_STAGE_DONE)
    call("vice_keyboard_type", text=f"SYS {ENTRY}\n")
    if not wait_hit(num, timeout=300):
        raise SystemExit(f"seed ${seed:04X} config {config}: table stage never finished")
    table_stage = dump(BASE, BASE + MASK_BYTES - 1, bank="ram")
    seen = dump(0x57, 0x57, bank="ram")[0]
    if seen != config:
        raise SystemExit(f"$57 reads {seen}, expected config {config}")

    num = arm(PHASE_DONE)
    call("vice_execution_run")
    if not wait_hit(num, timeout=300):
        raise SystemExit(f"seed ${seed:04X} config {config}: phase never finished")
    phase_end = dump(BASE, BASE + MASK_BYTES - 1, bank="ram")
    clear_checkpoints()
    return {"tableStage": table_stage, "phaseEnd": phase_end}


def digest(b):
    return hashlib.sha256(b).hexdigest()[:16]


def capture_fixtures(code, seeds, configs):
    """Write a fixture the Swift port can assert against.

    **Digests, not masks.** A land mask is 12,800 bytes of map produced by
    Ozark Softscape's generator, and this project does not ship map data — the
    existing fixtures are numeric behavior of general-purpose routines, which is
    a different kind of thing. A SHA-256 per case is a bit-exact equality test,
    carries no game data at all, and is 16 characters.

    The land count and blob areas travel with it so a failure is diagnosable:
    a digest mismatch alone says only "wrong", while the counts say whether the
    port is slightly off or building the wrong world entirely. Both are summary
    statistics, not a map. Full masks are written to `local/` — gitignored — for
    when a real diff is needed.
    """
    from wm_config import blobs, mask_bits

    maskdir = os.path.join(ROOT, "local", "wm_masks")
    os.makedirs(maskdir, exist_ok=True)
    cases = []
    for seed in seeds:
        for config in configs:
            # Capture twice and compare. Determinism here is an assumption the
            # whole oracle rests on, and it has been wrong once already: an
            # earlier capture of seed $0001 config 0 produced a mask differing
            # by a single isolated cell from every run since. Seven consecutive
            # runs now agree, the disk is not an input, a hard reset does
            # reinitialize RAM, and the frame counter feeds only the watchdog at
            # $2467 -- so that one observation is still unexplained. Verifying
            # each case rather than trusting it turns a silent bad fixture into a
            # loud failure.
            stages = land_mask(code, seed, config)
            again = land_mask(code, seed, config)
            for stage in stages:
                if stages[stage] != again[stage]:
                    raise SystemExit(
                        f"seed ${seed:04X} config {config} {stage}: NOT "
                        f"reproducible -- two runs differ, so this fixture "
                        f"cannot be used as a port oracle")
            case = {"seed": seed, "config": config}
            for stage, mask in stages.items():
                open(os.path.join(maskdir, f"{seed:04X}_{config}_{stage}.bin"),
                     "wb").write(mask)
                case[stage] = {
                    "sha256": hashlib.sha256(mask).hexdigest(),
                    "landCells": sum(bin(b).count("1") for b in mask),
                    "blobAreas": blobs(mask_bits(mask)),
                }
            cases.append(case)
            print(f"  seed ${seed:04X} config {config}: "
                  f"table {case['tableStage']['landCells']:6d} cells / "
                  f"{len(case['tableStage']['blobAreas'])} masses -> "
                  f"phase {case['phaseEnd']['landCells']:6d} cells / "
                  f"{len(case['phaseEnd']['blobAreas'])} masses", flush=True)

    out = os.path.join(ROOT, "SevenCitiesCore/Tests/SevenCitiesCoreTests/"
                             "Fixtures/landmass_reference.json")
    with open(out, "w") as f:
        json.dump({
            "description": "Land mask at $5700 from the original 6502, seed "
                           "pinned and the raster IRQ's entropy stir removed. "
                           "Two stop points per case: tableStage is $280A, where "
                           "the $2286 command table finishes; phaseEnd is $2894, "
                           "after the further random(2..8) radius-3 islands the "
                           "phase adds. Digests only — no map data.",
            "tableStageAddress": TABLE_STAGE_DONE, "phaseEndAddress": PHASE_DONE,
            "base": BASE, "width": 256, "height": 400, "bytesPerRow": 32,
            "cases": cases,
        }, f, indent=1)
    print(f"\nwrote {len(cases)} cases -> {os.path.relpath(out, ROOT)}")
    print(f"full masks (gitignored) -> {os.path.relpath(maskdir, ROOT)}")


def main():
    code = open(f"{ROOT}/local/game3.bin", "rb").read()

    if "--fixtures" in sys.argv:
        capture_fixtures(code, seeds=(0x1234, 0xBEEF, 0x0001), configs=(0, 1, 2))
        return

    trials = [(0x1234, 0), (0x1234, 0), (0x1234, 2), (0xBEEF, 0)]
    results = []
    for seed, config in trials:
        mask = land_mask(code, seed, config)
        land = sum(bin(b).count("1") for b in mask) / (256 * 400) * 100
        print(f"  seed ${seed:04X} config {config}: {digest(mask)}  {land:5.2f}% land",
              flush=True)
        results.append(mask)

    same_seed = results[0] == results[1]
    diff_config = results[0] != results[2]
    diff_seed = results[0] != results[3]

    print()
    print(f"  same seed + config reproduces : {'yes' if same_seed else 'NO'}")
    print(f"  different config differs      : {'yes' if diff_config else 'NO'}")
    print(f"  different seed differs        : {'yes' if diff_seed else 'NO'}")
    if same_seed and diff_config and diff_seed:
        print("\nthe land-mass phase is now a pure function of (seed, config)")
    else:
        print("\nNOT deterministic yet — another entropy source is in play")


if __name__ == "__main__":
    main()
