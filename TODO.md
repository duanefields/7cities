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
- [ ] **Settle what `game` is.** Still the gate on the game's rules.

      Measured, not inferred: pressing F3 at the title menu loads the World
      Maker, and RAM `$0800..` then matches `game3` in **18,430 of 18,432
      bytes (99.99%)**, the two differences being runtime self-modification.
      **The load path does not transform files.**

      That constrains `game` hard. It is 36,096 bytes loading at `$0800`, the
      same size and address as the 36 KB of real code (1114 `JSR`) dumped from
      `$0800-$94FF` in an earlier session. Equal size **rules out compression**,
      so if `game` becomes that code the transform is an in-place cipher. But
      differential crib searches — which cancel the key rather than guess it —
      find nothing for either an XOR key or an additive key, across 10 words and
      4 encodings.

      Next experiment: run the **F7** path with a map disk. F7 alone dissolves
      the title and returns to the attract loop without loading anything, which
      suggests it checks for a map disk first. `d64/HISTMAP.D64` is accepted as
      one (see NOTES.md), so attach it at the prompt and sample `$0800-$94FF`
      through the load with `tools/watch_unpack.py`. Either `game`'s bytes
      appear at `$0800` and are then transformed in place — locating the cipher
      — or they never appear and `game` is a decoy.
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
