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
- [x] ~~**Settle what `game` is.**~~ **Solved: it is enciphered, not packed.**
      Watching the live game showed F7 loading it verbatim into `$0800-$94FF`
      (99.60% match) and then transforming it in place, 36,096 bytes in and out.
      Equal size rules out compression. `tools/catch_decrypt.py` freezes the
      machine at that instant for a clean plaintext, and the cipher is a fixed
      byte substitution that reproduces `$0800-$8BFF` with **zero errors**.
      `tools/decrypt_game.py` now decrypts the main program with no emulator.
- [ ] **Disassemble the decrypted main program.** This is where the game's rules
      live — movement and pace, the Old World and the court, natives and trade,
      scoring — and where the terrain charset generator must be, since the
      charset at `$A800` is built at runtime and appears nowhere on either disk.
      `local/game_decrypted.bin` is the starting point.
- [ ] **Find the closed form of the cipher, or the routine that computes it.**
      A nicety, not a blocker. The table is a bijection but not affine over
      GF(2) or mod 256, and does not factor into short `EOR`/`ADC`/`SBC`
      compositions. It does not appear anywhere in `$9500-$FFFF`, so the
      decryptor computes it rather than looking it up. Its structure looks
      deliberate — within a row, `out = r ^ ((r & 4) << 1)` with
      `r = ($A - lo) & $F` — so a closed form probably exists.
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
- [x] ~~**Fill in the missing original tiles.**~~ ~~**Identify the exploration
      view's composition step.**~~ **Both solved, statically.** The view draws
      terrain as redefined characters, but only the *charset* is built at
      runtime — the tile bitmaps are static data in the main program. Decrypt
      `game` and `tools/extract_tiles_static.py` reads all 16 straight out, no
      emulator and no captured pixels. One tile is 2x2 characters (32 bytes);
      the dispatch table at `$5529` gives the pattern per terrain value and
      matches the enum from `$1566`. Water is the exception — it points at a RAM
      buffer because it animates. See NOTES.md for the layout and palette.
- [ ] **Wire the static tiles into the extractor and viewer.** `extract.sh`
      should emit the original tileset from the user's own disks so the viewer
      defaults to classic art without needing a captured frame. This replaces
      `local/original_tiles.json`, which came from a screenshot and had
      reconstructed rivers, villages and mountain.
- [ ] **Animate water.** Entries `$0`/`$1`/`$2` point at RAM buffers driven by
      the `EOR #$55` pass at `$4057`, which swaps multicolor pixel pairs. Worth
      reproducing for fidelity.
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
