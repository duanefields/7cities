# Seven Cities of Gold — a macOS remaster in progress

Reverse engineering *Seven Cities of Gold* (Ozark Softscape / Electronic Arts, 1984) from the
original Commodore 64 disks, and rebuilding it for macOS in Swift.

The goal is fidelity underneath and a modern surface on top: the simulation's rules, stats and
randomness recovered from the original binaries and verified against them, presented at native
resolution with smooth scrolling and native conveniences.

**Status: milestone zero.** The map format is fully decoded and there is an explorable viewer.
The game itself — trade, natives, the court, scoring — is not started. See `TODO.md`.

## You must supply your own disks

**No game data ships here, and none ever will.** The code, graphics, text and maps are
copyright Electronic Arts / Ozark Softscape. This repository contains only original engine code
plus tools that read data from disk images *you already own*.

## Quick start

```bash
mkdir -p d64
# copy your own images in:
#   d64/7CITIES1.D64    program disk, side 1
#   d64/7CITIES2.D64    program disk, side 2 — the historical map

./extract.sh        # decodes the map into assets/
make run            # opens the viewer
```

`make` on its own lists the other targets. Requirements: macOS and Swift 6 (Xcode 16 or the
standalone toolchain). **No emulator and no Python are needed.**

Only side 2 is required, because that is where the historical map lives. Side 1 holds the fonts
and the World Maker and is used by the deeper reverse engineering tools.

## What the viewer does

- **World menu** — the classic map of the Americas, or **Generate New World**, which makes a
  fresh one every time you pick it
- **Tiles menu** — original C64 art or custom tiles drawn for this port
- Walk with the arrow keys, the numpad, or the `YUI`/`HK`/`NM,` cluster
- Drag or scroll to pan, `=`/`-` to zoom, `0` to fit the whole world, `f` to re-center

The world is 256 x 400 tiles at roughly three miles each.

Original tiles are lifted from a captured frame of the running game and are therefore optional;
without them the viewer falls back to the custom tiles and says so in its title bar. Producing
them is the one step that still needs an emulator — see `TODO.md`.

## Opening it in Xcode

This is a Swift package, so there is no `.xcodeproj` to check in and let drift:

```bash
open SevenCitiesCore/Package.swift
```

Xcode builds, runs and debugs it natively. To run the viewer from Xcode, edit the `MapViewer`
scheme and pass the absolute path to `assets` as an argument. From the command line,
`swift build` and `swift test` work as usual.

## Layout

```text
extract.sh          decode your disks into assets/
Makefile            extract, run, test, build, clean
SevenCitiesCore/    the Swift package
  Sources/SevenCitiesCore   simulation and decoding, no UI
  Sources/Extract           the disk extractor
  Sources/MapViewer         the SpriteKit viewer
tools/              Python research tools (not needed to build or run)
NOTES.md            the reverse engineering record
TODO.md             what is still missing
d64/                your disk images — gitignored
assets/             extracted data — gitignored
```

`tools/` holds the archaeology: a D64 reader, a recursive-descent 6502 disassembler, harnesses
that drive VICE to verify ported code against the original, and the map and tile extractors
that came first. None of it is needed to build or play; it is how the format was worked out,
kept so the findings can be reproduced and checked.

## Fidelity

Ported code is not trusted until it matches the original. `tools/rng_reference.py` loads the
original 6502 routine into an emulator, runs it, and captures the output as a test fixture; the
Swift tests then assert the port reproduces it exactly.

| Component                       | Status                                                 |
| :------------------------------ | :----------------------------------------------------- |
| Fastloader / disk sector order  | Solved from the loader's own command string            |
| Map format                      | Solved — blocked sectors, nibble tiles, 256x400         |
| Terrain vocabulary              | Solved — from the game's own name table                |
| World Maker RNG                 | **Ported and verified** against the original 6502      |
| Multiply / divide helpers       | **Ported and verified** against the original 6502      |
| World generation                | Placeholder — *a* generator, not *the* one             |
| The game                        | Not started                                             |

The map decode was cross-checked against an independent community dump of the historical map
and agrees on every continent, island chain, river course and mountain range.

`NOTES.md` records how each of these was established, including the approaches that failed.

## License

Engine code here is original work, released under the MIT license (see `LICENSE`). It is not
affiliated with or endorsed by Electronic Arts. *Seven Cities of Gold* and all original game
assets remain the property of their respective rights holders.
