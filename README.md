# Seven Cities of Gold — a macOS remaster in progress

Reverse engineering *Seven Cities of Gold* (Ozark Softscape / Electronic Arts, 1984) from the
original Commodore 64 disks, and rebuilding it for macOS in Swift.

The goal is fidelity underneath and a modern surface on top: the simulation's rules, stats and
randomness recovered from the original binaries and verified against them, presented at native
resolution with smooth scrolling and native conveniences.

**Status: milestone zero.** The map format is fully decoded and there is an explorable viewer.
The game itself — trade, natives, the court, scoring — is not started. See `TODO.md`.

![The viewer showing the Gulf of Mexico and the Caribbean, drawn with the original C64 terrain
art](images/viewer-classic-map.webp)

The classic map and the terrain art above both came out of the original disks — the art is not
a screenshot of the game, but the game's own tile data, read out of its main program and
redrawn. See [What the viewer does](#what-the-viewer-does).

## You must supply your own disks

**No game data ships here, and none ever will.** The code, graphics, text and maps are
copyright Electronic Arts / Ozark Softscape. This repository contains only original engine code
plus tools that read data from disk images *you already own*.

## This project is heavily AI-assisted

Almost all of the code, the reverse engineering and the notes here were written by
Claude, working from my direction. I am saying so plainly because it changes how you
should read the claims in `NOTES.md`.

What that means in practice:

- **Findings are verified where they can be.** Ported routines are asserted against
  output captured from the original 6502 running under an emulator; the map decode was
  cross-checked against an independent community dump; the terrain art was checked
  against the game's own rendering. Where something is a guess or a simplification, it
  says so.
- **`NOTES.md` records the wrong turns too**, deliberately — a cipher that was declared
  absent and then found, a variant formula rejected twice on bad evidence, several
  confident conclusions drawn from measurements that could not support them. That record
  is more useful than a clean narrative, and it is a fair sample of how the work went.
- **Commit messages are long on purpose.** They carry the reasoning and the corrections,
  so the history is readable as an account of the investigation rather than a list of
  changes.

Treat the reverse-engineering conclusions as well-evidenced but not peer-reviewed. If you
know this game's internals and something here is wrong, I would like to know.

## Quick start

You do not need the game to try this. Clone it and run:

```bash
make run            # opens the viewer on a freshly generated world
```

To get the *classic* map and the original terrain art, add images of disks you own:

```bash
mkdir -p d64
#   d64/7CITIES1.D64    program disk, side 1 — the terrain art
#   d64/7CITIES2.D64    program disk, side 2 — the historical map

./extract.sh        # decodes both into assets/
make run
```

Or skip all of that and use the app: **File ▸ Import Disk Images…** does the same thing from a
file picker.

`make` on its own lists the other targets. Side 2 carries the historical map; side 1 carries
the terrain art, the fonts and the World Maker. Either can be supplied without the other.

## Dependencies

**To build and run the port — one dependency, and it is the toolchain:**

| Requirement | Version | Notes                                       |
| :---------- | :------ | :------------------------------------------ |
| macOS       | 14+     | declared in `Package.swift`                 |
| Swift       | 6.0+    | Xcode 16, or the standalone toolchain       |

There are **no Swift package dependencies** — `Package.swift` has an empty dependency list, so
`swift build` fetches nothing. No emulator, no Python, no network access. AppKit and SpriteKit
are system frameworks.

**To run the research tools in `tools/` — optional, and needed by nobody who just wants to
build or play:**

| Requirement | Needed by                                                |
| :---------- | :-------------------------------------------------------- |
| Python 3.9+ | all of them                                                |
| Pillow      | the 7 that render or compare images (`pip install pillow`) |
| [vice-mcp](https://github.com/barryw/vice-mcp) | the 6 that drive the emulator |

`vice-mcp` is a fork of VICE with an MCP server built in — Homebrew's VICE will not work.

### What the emulator is still for

Nothing on the build, extract or run path. Everything a user does is static. It is needed for
exactly two things:

- **Differential verification.** `rng_reference.py` and `arith_reference.py` execute the
  original 6502 and capture its output as test fixtures, which the Swift tests then assert
  against. Those fixtures are committed, so you only need the emulator to regenerate or extend
  them — which is how the World Maker phases and the game rules will be verified as they are
  ported.
- **Re-deriving the cipher.** The substitution table in `GameCipher` was recovered from a
  known-plaintext pair captured live by `catch_decrypt.py`. Its closed form was never found and
  the generating routine is not in RAM, so the table **cannot currently be re-derived
  statically**. If you would rather not take it on trust, that is the tool that reproduces it.

## What the viewer does

- **World menu** — the classic map of the Americas, or **Generate New World**, which makes a
  fresh one every time you pick it
- **Tiles menu** — original C64 art or custom tiles drawn for this port
- Walk with the arrow keys, the numpad, or the `YUI`/`HK`/`NM,` cluster
- Drag or scroll to pan, `=`/`-` to zoom, `0` to fit the whole world, `f` to re-center

The world is 256 x 400 tiles at roughly three miles each.

Both the classic map and the original terrain art come from your own disks, with no emulator.
The art is not a screenshot: the game draws terrain as redefined characters, and the tile
bitmaps turned out to be static data inside its main program, so `extract.sh` reads them
directly. If no art has been extracted the viewer falls back to the custom tiles and says so in
its title bar.

## Opening it in Xcode

```bash
open app/SevenCities.xcodeproj
```

Build and run. There is nothing to configure: no scheme arguments, no paths. The app keeps its
assets in `~/Library/Application Support/SevenCities/assets`, generates a world if none are
there, and has **File ▸ Import Disk Images…** for pulling the classic map and the original art
off disks you own. You never need a terminal.

The project is a deliberately thin wrapper: it owns the bundle, the menu bar and the launch,
and depends on `SevenCitiesCore` as a **local Swift package**. All the behavior lives in the
package's `ViewerKit` library, which the `MapViewer` command-line front end uses too, so the
two cannot drift apart. Because the app target references the package rather than duplicating
it, adding a file to the package needs no project edit.

Prefer the package on its own? `open SevenCitiesCore/Package.swift` works as well, and
`swift build` / `swift test` behave as usual.

## Layout

```text
extract.sh          decode your disks into assets/
Makefile            extract, run, test, build, app, clean
app/                thin Xcode app wrapper — bundle and launch only
  SevenCities.xcodeproj     depends on the package below, duplicates nothing
SevenCitiesCore/    the Swift package, where everything actually lives
  Sources/SevenCitiesCore   simulation, decoding and extraction, no UI
  Sources/ViewerKit         the SpriteKit viewer, shared by the app and the CLI
  Sources/Extract           the command-line extractor
  Sources/MapViewer         command-line front end for the viewer
images/             screenshots used by this README
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
| `game` cipher                   | Solved — fixed byte substitution, verified exactly     |
| Terrain tiles                   | Solved — read from the program, no emulator            |
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
