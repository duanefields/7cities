# TODO

Milestone zero is a decoded map and an explorable viewer. This tracks what is
still missing, roughly in order of value. `NOTES.md` holds the reverse
engineering record; this holds the work.

## Fidelity gaps — things that are approximations today

- [ ] **Port the real World Maker.** `WorldGenerator` is *a* world generator,
      not *the* one. Ozark Softscape's runs a plate tectonics model and a
      cultural diffusion model in 18 KB of 6502. The pipeline is mapped
      (`$0E20`, phases at `$2AE9`, `$2D23`, `$2E32`, `$3961`, `$3EAD`) and its
      RNG and arithmetic are already ported and verified against the original —
      the generation phases themselves are not.
- [x] ~~**Write the depacker.**~~ **There is no depacker — nothing is packed.**
      The loader ignores the directory entirely: it issues raw `U1:` block reads
      from track 1 sector 0, sectors 0-19 per track, and stores every byte
      verbatim (`JSR $FFA5 / STA ($2C),Y`). The file named `game` that looked
      encrypted is simply not the program and is never loaded. See NOTES.md.

      `tools/extract_stage.py` now lifts a stage straight off a disk image with
      no emulator. Stage 1 (tracks 1-3, `$0800-$33FF`, entry `$1038`) yields
      real 6502 and the title text, credits included.
- [ ] **Extract the remaining stages.** Stage 1 is out; the game proper, the
      World Maker and the terrain art are on the other code tracks (11-17 and
      23-25). Pin down which `--skip` goes with which load by reading the
      callers of `JSR $C003` in stage 1 — each sets a start page, end page and
      checksum in `$C003`/`$C004`/`$C005` before re-entering the loader.

      This is what unblocks the original tiles and the game rules, and it is now
      a static disassembly job rather than an emulator job.
- [ ] **Fill in the missing original tiles.** Rivers, villages and a clean
      mountain were absent from the captured frame and are reconstructed.
      Capturing more demo frames would replace them with the original's pixels.
- [ ] **Identify the exploration view's composition step.** The original draws
      terrain procedurally into redefined characters rather than from a tile
      atlas; reproducing that exactly is a separate job from drawing our own.

## Unknowns still in the map data

- [ ] Nibble `3` — 14 cells, all in the top-right corner. Edge or metadata,
      unidentified. The terrain table calls index 3 `SHIP`.
- [ ] How the raw map nibble maps to the game's terrain enum. The enum at
      `$1566` is not indexed by the raw nibble, and the translation has not been
      found.

## The game itself — none of this is started

- [ ] Movement rules: pace, terrain cost, rivers as the fast route inland.
- [ ] The Old World: court, outfitting, ranks, the promotion ladder.
- [ ] Natives: villages, trade, attitude, the peaceful/hostile axis.
- [ ] Scoring and the 1540 win condition.
- [ ] Save games (they live on the map disk in the original).
- [ ] Sound. No SID music has been located yet.

## Port infrastructure

- [ ] Differential test harness driving the original under vice-mcp and
      comparing state against `SevenCitiesCore`.
- [ ] iPad target. The game is 8-way plus one button, so it should suit touch.

## Viewer polish

- [ ] Terrain-aware movement instead of free cursor movement.
- [ ] Minimap or coordinate jump.
- [ ] Remember window size, zoom and position between launches.
