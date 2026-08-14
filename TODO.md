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
      count. **`$2AE9` is what reads them** — it walks the chosen table and
      writes nibble `$03` wherever it finds plain.
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
- [x] ~~**Find out what reads `$77`-`$81`.**~~ **`$47DF` does**, and it is the
      first thing the village phase looks at: the two sites the mirror picked
      become the first two villages on the map. See NOTES.md. Original note:
      `$44EF` files two sites there —
      column, row, a row-past-`$D0` flag and a kind of 9 or 7, one of each. Two
      advanced civilizations is the obvious guess and is only a guess.
- [x] ~~**Port the walk's `$50` mode (`$1860`, `$186C`), which builds paired
      continents.**~~ **Done**, along with the isthmus at `$17C8` and the recovery
      at `$1A48` that it turned out to need. See NOTES.md.
- [x] ~~**Build a virtual 1541 for `sim6502`.**~~ **Done** (`tools/vdrive.py`).
      The World Maker now runs past the land-mass phase and writes a real map
      disk — 200 sectors, tracks 22 to 34 — whose land and water match the Swift
      port's mask exactly. `tools/wm_disk.py` drives it.
- [x] ~~**Find out why the terrain phases do not finish.**~~ **Fixed.** The drive
      served the error status for every `TALK`, so `U1` reads came back as 256
      bytes of `00, OK,00,00`. Serving the channel's buffer instead finishes the
      whole World Maker in 320 seconds — 414 sector writes, terrain, rivers and
      villages. `tools/wm_disk.py --seed --config --out`.
- [ ] **Port the terrain phases.** Now unblocked, and the same loop applies as
      for the land mass: capture from the interpreter, port, diff. The pipeline
      at `$0E20` runs once per 208-row band and is mapped in NOTES.md — `$2AE9`
      water depth, `$2E32` terrain, `$3EAD` rivers, `$47DF` villages, `$2D23` a
      parameterized spread run twice, `$2C14` the band writer. Start with
      `$2AE9`. **Done so far:** `$2AE9` and `$2D23` are exact against the band
      digest at the next phase's entry; the landmass tables and `$1D42`'s fixup
      of them are exact; `$0B16`'s scattered draw is exact across 400 real calls,
      value and generator state both. `$2E32` is exact except for `$380D` — its
      three band sweeps against the band digest, and `$2F8C`, `$3134` and `$31E6`
      against the writes the original made, 892, 212 and 490 of them.

      **What is left in `$2E32` is `$380D`, and it belongs with the rivers.** It
      picks a spot in the middle of the mountain spine, checks it clear of the
      lake marks, and then calls `$32CC` and `$4006` — the river engine `$3EAD`
      also uses. 5,007 of the first landmass's 6,601 writes. Porting it is
      porting the river engine, so do `$3EAD` and this together.

      **Sizing**, measured as distinct instruction addresses actually executed,
      against the land-mass phase's 2,276 as the yardstick: `$2AE9` 658,
      `$2D23` 192, `$2E32` 1,750, `$3961` 1,459, `$3EAD` 1,635, `$47DF` 1,092,
      `$4CF2` 83, `$2C14` 419 — about 7,200 unique in all, roughly three times
      the land-mass phase. That one took a day *with* its generator, arithmetic,
      command table and clearance test already ported. The harness is far better
      now and the band, the bounding box and the nibble addressing are done, but
      this is days rather than a day, and `$2E32`, `$3961` and `$3EAD` are the
      bulk of it. Every phase read so far has come in bigger than it looked, so
      treat the numbers as a floor.

      **That estimate is now measured to be far too high, and the reason is
      worth keeping.** `$380D`, `$3961` and `$3EAD` are not three phases; they
      are three entries into one water engine, and they share 776 addresses
      between all three. Measured: 1,060, 1,459 and 1,635 distinct addresses
      each, **1,996 in union** — one phase's worth of work rather than three,
      and about the size of the land-mass phase. The 7,200 figure counted the
      same code up to three times.

      So what is actually left of the World Maker is roughly: the water engine
      at 1,996, `$47DF` villages at 1,092 (which overlaps it too, since it also
      draws through `$0FD3` — measure before believing that number), `$2C14`
      the band writer at 419, and `$4CF2` at 83 which needs no port. Call it
      3,000-3,500 rather than 7,200.
- [x] ~~**Confirm the band structure.**~~ **Done.** 208 rows, and two bands
      cover the map: rows 0-207 and 192-399, overlapping by sixteen. The nibbles
      *do* overwrite the 1-bit mask at `$5700` in place, and the bands run top
      down. Verified by unpacking the port's own mask and matching the
      original's band digest exactly.
- [ ] **Port the water engine.** The next thing, and the biggest. `$380D`,
      `$3961` and `$3EAD` are three entries into one walker; `$32CC` tells it
      which by writing the caller's two addresses into the operands of `$3450`
      and `$348A`. NOTES.md has the shape. Ported so far, in `RiverEngine`: the
      routing tables at `$329C`, `$333C`'s chooser, `$33B7`'s aim, `$3300`'s
      recorded step and `$363B`'s straight run — the forward half of the walk.

      **`$2E32` is complete.** Every one of the 6,658 writes its range half
      makes in the first band matches the original, in both configurations the
      fixture holds — spine, spur, clearing, all ten sourced rivers with their
      unwinds, their fifty-one mouths and their swamps, and the arms. That
      verifies most of the water engine with it: `$32CC`, `$333C`, `$33B7`,
      `$3300`, `$33EF`, `$3531`, `$369F`, `$3755`, `$3D97` and `$3E53`.

      **The water engine is done.** `$380D`, `$3961` and `$3EAD` all reproduce
      the original's writes exactly in the first band — 5,007, 259 and 1,311 of
      them — and each leaves the generator where the original leaves it, which
      is what let the next one be graded at all.

      **Grade it with `tools/pipeline_trace.py`**, which records every write of
      every phase tagged with the river that made it. Band 0 of seed `$1234`
      config 0: `$380D` draws 10 rivers inside `$2E32` (16, 36, 339, 259, 10,
      20, 1941, 50, 1715, 678 writes), `$3961` draws 8, `$3EAD` draws 21. A port
      can be checked one river at a time.
- [x] ~~**Port `$47DF`, the villages.**~~ 127 writes a band, all of them nibble
      `$F`, and everything before it in the pipeline is exact — so it can be
      graded straight off `pipeline_reference.json` the moment it is written.

      **Read it first in NOTES.md.** The phase itself is only half the work; its
      budget is computed two phases earlier, during the mask unpack, and carried
      in zero page. The chain is `$0C9B` -> `$1047`/`$1060` counting
      village-eligible quadrants into `$70`-`$73`, then `$0D5D` -> `$40FA`
      turning those into `$6C`/`$6D` (how many villages a band may have),
      `$6E`/`$6F` (the draw a quadrant must beat) and `$82`/`$83`. None of that
      is in `$47DF`, and a port that starts at `$47DF` will not find it.

      **Everything the phase is handed is ported and exact** for all three
      configurations. `VillageBudget.budget(for:)` goes from a finished
      land-mass run to `$6C`/`$6D`, `$6E`/`$6F` and `$82`/`$83` — 121/125 with
      thresholds 127/127 for configuration 0, 46/202 with 102/102 for 1, and
      146/95 with 0/0 for 2 — including the two deductions, which come off the
      run rather than out of the fixture.

      **`$47E1` and `$4823` are ported and exact** — the two sites the mirror
      chose and the one thrown at random after them, the first three villages
      on the map, at (126,176), (214,32) and the draw that follows.

      `$486F`'s walk over the strips is **written and not yet right**: it
      reproduces the first five villages and then drifts. The cause is measured.
      `$49A1` calls `$4AAB` after every strip, and `$4AAB` is not the pure
      bookkeeping it looks like — it surveys the strip into `$87` onward and
      `$EB00`, and then, for any strip that held land, takes a draw at `$4B7F`
      and on roughly one in ten goes on to place something through `$4B91`.
      Measured: the generator advances exactly one step per strip from `$CE`
      down, and not at all for `$CF`, which is the strip that held nothing.

      `$4AAB`'s draws are now in — one per strip that held ground, plus two a
      try on the one-in-ten that goes hunting — and it does **not** write to the
      band: `$4BBB` files into `$E600`/`$E614`/`$E628` and nothing else. The
      port still diverges at the sixth village, in strip `$CD`, which means
      something in the quarter loop is still a draw out. Instrument the port and
      the interpreter at the draw level for that one strip; that is the
      technique that has found every one of these.

      **And `$47DF` has a fourth section nobody had noticed.** Measured over a
      whole band: 127 villages placed, of which 2 are the sites and the random
      one, 119 come from `$4949` (the strip quarters and the strip-wide retry),
      and the remaining 6 come from `$49F2` — which walks the *landmass* tables
      after the strips are done and calls `$42CD` from `$4A48` and `$4AA3`. The
      budget `$6C` runs to exactly 0 over the first 121, so `$49F2`'s six are
      placed outside it.

      `$42CD`, which picks a village's *kind*, takes no draws at all and does
      not touch the band, so the map does not depend on it.
- [x] ~~**Port `$2C14`, the band writer.**~~ **Done, and it is not a writer.**
      Four instructions: sweep the band and turn every `$3` back into `$0B`.
      That is the 213 cells, and it answers what `$03` was for — scaffolding the
      middle phases stand on, put back at the end. Nothing in it touches the
      disk, so the phase table's old description was wrong.
- [x] ~~**Assemble the second band.**~~ **Done.** Both bands reproduce the
      original's, and the generator ends where the original's ends — which is
      every draw of every phase of both bands, in order. `WorldMaker.world(of:)`
      is the whole pipeline.

      The seam works the way the disk makes it work: `$0C9B` unpacks all four
      hundred rows and writes them out, `$0F0C` reads a band back at the top of
      each `$0E20` and `$0F47` writes it out at the bottom — so by the time the
      second band is read, the sixteen rows it shares with the first have been
      overwritten by the first band's *finished* terrain.
- [ ] **Replace `WorldGenerator` in the viewer** with the real pipeline. This is
      the point of all of it.
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
- [ ] **Build an input-driven oracle before porting game rules.** The World
      Maker was fast to port because it is a pure function with a perfect diff —
      seed in, 51,200 bytes out. Every structural correction to the coastline
      walker came from a diff and not one from reading. Game rules have the
      opposite shape: legible code, no oracle, because state evolves from player
      input. The same trick that unblocked terrain should work — run `game` in
      `sim6502` with `vdrive.py` serving a generated map disk, stub the joystick
      and keyboard to a scripted input sequence, and diff the state (position,
      supplies, crew, date, rank) after *n* frames. Probably a day, and it makes
      everything after it the same capture-port-diff loop.
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

- [ ] Nibble `3` — 14 cells, all in the top-right corner of the historical
      disk, and **none at all** on a freshly generated one. `$2AE9` writes it at
      each of the second wave's islands and something before the band reaches
      disk takes it away again, so it is scaffolding rather than terrain. What
      stands on it is the open question; the second `$2D23` is the suspect.
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
