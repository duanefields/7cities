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
- [ ] **Settle what `game` is.** Still the gate on the game's rules. It is
      36,098 bytes loading at `$0800` (so exactly `$0800-$94FF`), with 66 `JSR`
      and zero `AND #$0F`, entropy 7.04 bits/byte, and it renders as noise as
      both a bitmap and a charset — so it is neither code nor plain graphics.

      Now established: the `$C000` loader is only the **first-stage** loader and
      contains no decompressor. It stores raw sectors verbatim
      (`JSR $FFA5 / STA ($2C),Y`), page-aligned, sectors 0-19 per track from
      track 1 sector 0. Whatever loads `game` is not it.

      Two live readings, which make different predictions:

      1. `game` is packed, and a depacker in stage 1 (or a later stage) expands
         it in place at `$0800`.
      2. `game` is never loaded, and the code seen at `$0800-$94FF` in RAM comes
         from other stages — `game` would then be a decoy.

      Settle it by watching `$0800` during the load — dump `$0800-$94FF` at
      intervals and find the moment `JSR` density jumps — rather than by
      inferring from the file. A previous attempt to argue this from the loader
      alone reached the wrong answer; see NOTES.md.
- [x] ~~**Extract stage 1.**~~ Done, statically, no emulator.
      `tools/extract_stage.py` lifts tracks 1-3 to `$0800-$33FF`: real 6502 plus
      the title text and the Ozark Softscape credits. Load address confirmed two
      independent ways. `tools/survey_stages.py` scores load addresses for other
      regions, and `tools/vmtrace.py` disassembles the loader's bytecode.
- [ ] **Find how stages after the first are loaded.** Stage 1's entry point is
      still unknown (the `$1038` in a RAM dump is a per-load parameter belonging
      to whichever stage loaded last). Nothing in stage 1 writes the loader's
      track/sector digits or its `$C003`/`$C004`/`$C005` parameters directly, so
      the re-entry protocol has not been found. This is the same question as
      "what loads `game`".
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
