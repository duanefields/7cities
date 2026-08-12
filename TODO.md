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
- [ ] **Write the depacker.** This is the gate on almost everything else, not a
      nicety: the game's rules all live inside `game.prg`, and the original
      terrain art cannot be extracted without it.

      What is established so far:

      - `game.prg` on disk matches its in-RAM form in **0.00% of bytes** — not
        one byte in 36,096, where even unrelated data would collide ~0.4% of
        the time.
      - **No chunk of the unpacked code appears anywhere on either disk image**,
        so it is genuinely transformed, not merely stored in a different order.
      - It is **not** a repeating XOR key, and the byte histograms differ, so it
        is not a permutation either.
      - `game2` and `game3` are **not** packed — they read as plain code and
        text straight off the disk. Whatever this is, it was applied only to the
        big file.
      - The `$C000` fastloader is plain code and is the natural place for the
        depacker to live. `$C047`-`$C25F` inside it is a large non-code region
        of repeating 2-3 byte groups that looks like a bytecode or table and has
        not been identified.

      Approaches tried and their status:

      - Write watchpoint inside the game's memory range: never fired. Watchpoints
        have been unreliable throughout this project.
      - Polling RAM during the load to catch a plain-then-transformed moment:
        not yet completed — the run kept failing on title-menu sync.

      Next: disassemble the `$C000` loader properly around its receive loop and
      look for a transform between taking a byte off the wire and storing it.
      Static analysis has consistently outperformed emulator automation here.
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
