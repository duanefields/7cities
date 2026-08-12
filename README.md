# Seven Cities of Gold — macOS remaster

A faithful, high-resolution remaster of *Seven Cities of Gold* (Ozark Softscape / Electronic
Arts, 1984) for macOS, reverse engineered from the original Commodore 64 disks.

The goal is fidelity, not reinterpretation: the simulation's stats, rules, and randomness are
recovered from the original binaries and verified against the original code running in an
emulator. The presentation is modernized — native resolution, smooth scrolling, native menus
and saves — while the simulation underneath stays true to 1984.

## You must supply your own game disks

**No game data is included in this repository, and none ever will be.** The original code,
graphics, text, and maps are copyright Electronic Arts / Ozark Softscape. This project ships
only original engine code plus tools that read data from disk images *you already own*.

Place your own images at:

```text
d64/7CITIES1.D64     program disk, side 1
d64/7CITIES2.D64     program disk, side 2 (historical map master)
```

These paths are in `.gitignore` and will not be committed.

## Status

Early. The simulation is being reverse engineered piece by piece, and each piece is verified
against the original before it is trusted.

| Component                     | Status                                                     |
| :---------------------------- | :--------------------------------------------------------- |
| Fastloader / disk sector order | Solved — read directly from the loader's command string    |
| Text and font extraction       | Solved                                                     |
| Map disk format                | **Solved** — blocked sectors, nibble tiles, 256x400 map     |
| World Maker RNG                | **Ported and verified** against the original 6502          |
| Multiply / divide helpers      | **Ported and verified** against the original 6502          |
| World Maker generation phases  | Mapped; land-mass phase entry located, data not yet decoded |
| Map viewer                     | **Working** — SpriteKit, zoom/scroll/walk, two tile styles  |

See `NOTES.md` for the full reverse engineering record, including what has been ruled out.

## Requirements

- macOS with Swift 6.0 or newer
- [vice-mcp](https://github.com/barryw/vice-mcp) — a VICE fork with an MCP server compiled in,
  used to verify ported code against the original. Homebrew's VICE will **not** work.
- `cc65` and `poppler` for disassembly and manual rendering
- Python 3 with Pillow for the extraction and analysis tools

## Layout

```text
SevenCitiesCore/    Swift package: the simulation. No UI dependencies.
tools/              Python: D64 reader, disassembler, VICE harness, extractors.
NOTES.md            Reverse engineering findings.
d64/                Your disk images (gitignored).
local/              Disassembly listings and extracted binaries (gitignored).
```

## Verification

Ported code is not trusted until it matches the original. `tools/rng_reference.py` loads the
original 6502 routine into VICE, executes it against a set of seeds, and captures the output
as a test fixture; the Swift test suite then asserts the port reproduces it exactly.

```bash
python3 tools/rng_reference.py local/game3.bin \
    SevenCitiesCore/Tests/SevenCitiesCoreTests/Fixtures/rng_reference.json
cd SevenCitiesCore && swift test
```

The RNG port currently matches the original across 5 seeds, 64 values each, including internal
register state at every step.

## License

Engine code in this repository is original work. It is not affiliated with or endorsed by
Electronic Arts. *Seven Cities of Gold* and all original game assets remain the property of
their respective rights holders.
