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
      The land-mass phase is now read in detail **and verified against the
      original**: the `$2286` table is three **command sequences** of
      `(size class, flags, count)`, and forcing each one with
      `tools/wm_config.py` builds exactly the predicted 2+2, 1+2 and 1+6
      landmasses. Placement is rejection sampling, and the land mask is 1 bit
      per cell at `$5700`, 32 B/row, confirmed visually by
      `tools/wm_landmask.py`. **The land-mass phase itself is now ported** —
      see below; what remains of the World Maker is the five phases after it.
      See NOTES.md.
- [x] ~~**Make the land-mass phase reproducible.**~~ **Done.** Patching the
      seeding site at `$20CB`, the raster IRQ's entropy stir at `$2406` and the
      configuration draw at `$2146` makes it a pure function of
      `(seed, config)`: the same pair reproduces all 12,800 bytes of the mask
      across separate emulator boots. `tools/wm_deterministic.py`, with
      `--fixtures` to capture `landmass_reference.json` (digests only — the
      mask is map data and is not committed).
- [x] ~~**Port the land-mass phase to Swift.**~~ **Done, all three
      configurations.** `LandMassStage.run(config:seed:)` goes from a seed to the
      original's 12,800-byte mask, checked at both of the phase's checkpoints
      against `landmass_reference.json` — the digests captured from the original
      under VICE — for all nine seed and configuration pairs.
- [x] ~~**Identify the two position tables at `$038C` and `$03B4`.**~~ **Done, and
      ported.** Below row 219 an island is filed into `$038C` as `(row, column)`;
      at or above, into `$03B4` as `(row - 192, column)`. `$03DC` keeps the last
      column filed, and `$2894` halves both indices to turn a byte offset into a
      count. What *reads* them is still unknown.
- [x] ~~**Trace the coastline outline.**~~ **Done, exactly.** All three fills —
      satellite, island and continent — reproduce every mask write the original
      made, in order, to the end of the fill: 23, 106 and 871 writes, the last
      with 155 backtracks. The fixture keeps a 150-event prefix for localizing
      faults plus a SHA-256 over the whole write sequence, since a continent's
      cells are generated map data and cannot be committed. See NOTES.md for the
      five findings that took, all from diffing traces rather than reading.
- [x] ~~**Port the interior flood fill at `$194A`.**~~ **Done, exactly.** With it
      and the mirror pass at `$1C89`, the whole land-mass stage now replays from
      an empty mask: eleven steps, 31,307 land cells, every write sequence and
      every mask digest matching the original bit for bit
      (`tools/interior_reference.py`, `InteriorFillTests`).
- [x] ~~**Port `$1666` and `$2629`, which decide the order.**~~ **Done.**
      `LandMassStage` runs the command table, the placement loop, the walk, the
      paired satellite search at `$2655` and the mirror from a seed alone, and
      matches the original on all nine seed/configuration pairs. It stops after
      the first command; see below.
- [x] ~~**Finish `$44EF`.**~~ **Done.** Both second-site searches, the twelve-draw
      average at `$0B16` and the `$EBCE` parameter. With it the command-table
      stage runs from a seed to the original's mask for configurations 0 and 2 —
      checked against `interior_reference.json`, whose own digests agree with the
      VICE-captured ones in `landmass_reference.json` on all nine cases.
- [ ] **Find out what reads `$77`-`$81`.** `$44EF` files two sites there —
      column, row, a row-past-`$D0` flag and a kind of 9 or 7, one of each. Two
      advanced civilizations is the obvious guess and is only a guess.
- [x] ~~**Port the walk's `$50` mode (`$1860`, `$186C`), which builds paired
      continents.**~~ **Done**, along with the isthmus at `$17C8` and the recovery
      at `$1A48` that it turned out to need. See NOTES.md.
- [x] ~~**Build a virtual 1541 for `sim6502`.**~~ **Done** (`tools/vdrive.py`).
      The World Maker now runs past the land-mass phase and writes a real map
      disk — 200 sectors, tracks 22 to 34 — whose land and water match the Swift
      port's mask exactly. `tools/wm_disk.py` drives it.
- [ ] **Find out why the terrain phases do not finish.** 900 million interpreted
      instructions (820s) leave the generator still inside `$0B16`. Either the
      phases need several times that, or one of `vdrive.py`'s stubs has it in a
      loop. Instrument which phase entries it reaches and how the distinct-PC set
      grows over time before assuming either.
- [ ] **Confirm the band structure.** The finished map is assembled on disk —
      51,200 bytes of nibbles will not fit in a C64 — and `$2C14` bounds its
      row counter at 208, which is very likely the band height. Still unknown:
      whether bands overwrite the 1-bit mask at `$5700` in place, and in which
      direction. Break on writes to `$5700` in a headless run.
- [ ] **Re-check `wm_trace.py`'s phase snapshots.** It waits for checkpoints by
      polling `vice_ping` for "paused", which fires for unrelated reasons — the
      same bug that misread three runs of `wm_config.py`. Its snapshots may have
      been taken mid-phase. Port it to poll `hit_count` and re-run.
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
- [x] ~~**Wire the static tiles into the extractor and viewer.**~~ Done.
      `extract.sh` emits `assets/original_tiles.json` from the user's own disks
      and the viewer renders the classic art by default. `SevenCitiesCore` gained
      `GameCipher` (the substitution), `TerrainTiles` (the `$5529` dispatch and
      2x2 unpack) and `DiskImage.fileContents(named:)`.
- [x] ~~**Render terrain the way the original does.**~~ Position-dependent
      composition for forest and swamp, verified tiles, an overview layer for
      zoomed-out browsing, and a palette setting. See NOTES.md for the four
      rendering faults this took and the two rules that came out.
- [x] ~~**Work out the mountain variant shift.**~~ Solved: the formula at
      `$5922` was right all along. The mountain region is 144 bytes = four `$24`
      slots, each with exactly the 4 bytes of headroom that `x & 3` needs, so
      `T[x & 1] + T[y & 1]` picks a slot and `x & 3` shifts within it. Twelve
      whole, distinct peaks. See NOTES.md for why it was wrongly rejected twice.
- [ ] **Animate water.** Entries `$0`/`$1`/`$2` point at RAM buffers driven by
      the `EOR #$55` pass at `$4057`, which swaps multicolor pixel pairs. Worth
      reproducing for fidelity.
- [x] ~~**Identify the exploration view's composition step.**~~ Solved and
      ported. The view is a 12x12 grid of unique character codes over 6x6 map
      tiles (`$3107`), the charset is double-buffered and rewritten per frame
      (`$31B4`), and each tile is composed by `$58B8` from its map position.
      See NOTES.md.

## Unknowns still in the map data

- [ ] Nibble `3` — 14 cells, all in the top-right corner. Edge or metadata,
      unidentified. The terrain table calls index 3 `SHIP`.
- [x] ~~How the raw map nibble maps to the game's terrain enum.~~ The evidence
      now says it is the identity. Under that assumption the dispatch table at
      `$5529` lines up entry-for-entry with the enum at `$1566`, and **97.7% of
      river endpoints point at water or another river** — a permuted mapping
      could not produce connected river courses. Treat as settled unless
      something contradicts it.

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
