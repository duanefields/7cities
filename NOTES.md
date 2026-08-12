# Seven Cities of Gold — port research notes

Working notes for porting *Seven Cities of Gold* (Ozark Softscape / EA, 1984, C64) to macOS.
Everything here was verified against the disk images in `d64/`, not assumed.

## Goal and constraints

- Faithful port: reproduce the real stats, ranks, and randomness from the original binaries.
- macOS first (SwiftUI shell + SpriteKit renderer); iPad to follow.
- Open source, not App Store. The user does not hold rights to the original.

### Architecture consequence of open-sourcing

Game mechanics are not copyrightable, but the extracted assets are. Ship no assets.

- `sevencities-extract` — CLI that reads *your own* D64s and emits a local asset bundle.
- `SevenCitiesCore` — pure Swift simulation. Deterministic, seedable, zero UI dependency.
- macOS app — SpriteKit renderer plus native menus, reads the extracted bundle at launch.

Keeping `SevenCitiesCore` UI-free also lets the differential test harness run it headless.
Give the repo a name other than the game's.

## Input scheme (decided)

The manual's entire control appendix is "Basic Joystick Control Information" — the game is
8-way plus one button, with no keyboard dependency. So one `Direction` enum plus `fire` is the
complete input surface. Three equivalent bindings:

| Scheme    | Directions                    | Fire    |
| :-------- | :---------------------------- | :------ |
| Numpad    | `7 8 9 / 4 6 / 1 2 3`         | `5`     |
| Arrows    | 4-way only                    | `Space` |
| J cluster | `Y U I / H K / N M ,`         | `J`     |

## Disk contents

Both images are standard 35-track D64s (174,848 bytes, no error info).

### `7CITIES1.D64` — program disk side 1

| File        | Load range     |   Bytes | Contents                                       |
| :---------- | :------------- | ------: | :--------------------------------------------- |
| `ea`        | `$02A8`        |     102 | BASIC stub, `LOAD"EA",8,1`                     |
| `ea` + `$9D` | `$C000-$C9FF` |   2,560 | EA fastloader / raw sector reader              |
| `game`      | `$0800-$94FF`  |  36,096 | Main game; ~6 KB data then ~30 KB of 6502 code |
| `game2`     | `$0800-$21FF`  |   6,656 | Old World / court sequence plus the text table |
| `game3`     | `$0800-$4FFF`  |  18,432 | World Maker plus disk formatter; 100% code     |
| `game4`     | `$1000-$23FF`  |   5,120 | Pure tabular data, ~3-byte period. Unidentified |

Plus 248 sectors (~62 KB) allocated but in no file, on tracks 1-10 and 34-35 — raw data the
fastloader reads directly. Contains the font and graphics.

### `7CITIES2.D64` — program disk side 2 (historical map master)

Two directory entries only; 409 sectors (~102 KB) of raw data on tracks 13-35. The one real
file is a 1.5 KB "MAP DISK COPY PROGRAM". Per the manual, side 2 is booted to *create* a map
disk, so the map format on this disk is the format the game reads.

## Solved: fastloader sector order

The `$C000` loader builds a literal 1541 command string and walks it as ASCII digits.

```text
$C2B9:  "I0:"  "#"  "U1:2,0,01,00"  "B-P:2,0"
                             ^^ ^^
$C2C4/$C2C5 = track tens/ones      $C2C7/$C2C8 = sector tens/ones
```

The increment routine at `$C1C8` (see `tools/loader-c000.disasm.s`):

```text
INC $C2C8 ; sector ones   -> wraps at '9'+1 -> INC $C2C7 ; sector tens
INC $C2C7 ; sector tens   -> wraps at '2'   -> INC $C2C5 ; track ones
INC $C2C5 ; track ones    -> wraps at '9'+1 -> INC $C2C4 ; track tens
```

Sector tens wraps at `'2'`, so the loader reads **sectors 0-19 only, then advances one track**.
Strictly sequential, no interleave, starting at track 1 sector 0.

This matters: tracks 1-17 physically hold 21 sectors, but sector 20 is never read. Dumping in
naive physical order inserts one stray sector per track and destroys alignment downstream.
Destination pointer is `$2C/$2D` (`STA ($2C),Y` in the byte-receive loop).

## Solved: text encoding (two different conventions)

The two modules do not agree, so decode per module:

| Module  | Encoding                                                              |
| :------ | :-------------------------------------------------------------------- |
| `game2` | Every byte has bit 7 set — real PETSCII uppercase, printed via KERNAL  |
| `game3` | Plain ASCII, terminated by the **last character** having bit 7 set     |

Verified: `game2` holds `C7 CF D6 C5 D2 CE CF D2` for `GOVERNOR` and contains no plain-ASCII
copy; `game3` holds `BUILDING LAND MASSES` as plain ASCII ending `... 45 53 20 20 20 20 A0`.
The `game3` form matches the custom ASCII-ordered font, which that module draws itself.

Recovered from `game2`: rank ladder (`CAPTAIN`, `CAPTAIN GENERAL`, `VICE GOVERNOR`,
`GOVERNOR`, `GOVERNOR GENERAL`, `VICEROY`), skill levels (`OBSERVER (DEMO)`, `NOVICE`,
`JOURNEYMAN`, `MASTER`), Old World locations (`SHIP PALACE PUB HOME OUTFIT`), court dialogue.

## Solved: font

A custom 8x8 set in **ASCII order** starting with space at index 0 — not PETSCII order. Lives
in the raw track region of disk 1, near offset 4600 of the tracks 1-10 stream. Exact offset
still needs pinning down.

## Solved: what makes a valid map disk

A real map disk has an **empty directory** — 0 entries, BAM showing 2/683 allocated. The World
Maker formats the disk and writes raw sectors without ever touching the BAM or directory.
`7CITIES2.D64` has two files on it, so the game refuses it: side 2 is the *master*, not a map
disk. Save games also live on the map disk.

`d64/BLANKMAP.D64` is a valid map disk generated in-emulator via the title menu's F3 (World
Maker), fed a blank D64 built by hand. Having a second, independently generated map in the
same format is what made structural analysis possible — diffing two maps separates format
from content in a way statistics on one map could not.

## World Maker (`game3`) — the current port target

Chosen over decoding the historical map because it is self-contained, has no dependency on the
unsolved map encoding, and generates worlds rather than reading one. Entry point is `$1E99`
(the file begins `4C 99 1E`). The generation pipeline is at `$0E20`:

```text
$0E20  JSR $0E92
$0E23  JSR $0F0C        ; subtree prints "BUILDING LAND MASSES" (routine $1F95)
$0E2A  JSR $0910        ; print "PLACING FOREST,MOUNTAIN,PLAIN"  (X=lo, Y=hi)
$0E2F  JSR $2AE9
       $13D3=$80  $13D4=$40  $2D70=$00  $2D74=$0F  $2DA6=$A2
$0E4C  JSR $2D23
$0E4F  JSR $2E32
$0E52  JSR $3961
$0E55  JSR $3EAD
       $2D70=$0F  $2D74=$00  $2DA6=$60
$0E67  JSR $2D23        ; same routine, second parameter set
$0E6E  JSR $0910        ; print "PLACING NATIVE VILLAGES"
       clear 24 bytes at $E2F1
$0E84  JSR $47DF
$0E87  JSR $4CF2
$0E8A  JSR $2C14
$0E8D  JSR $090C
```

`JSR $0910` with X/Y = string pointer is the status-message printer. `RUNNING
RIVERS,TRIBUTARIES` is printed by routine `$380D`, called from `$30BB`, so rivers run inside
the `$2E32`/`$3961` subtree.

**Correction:** an earlier note here claimed `$0F0C` was the land-mass phase and `$1F95` its
printer. Both were wrong — they came from a nearest-preceding-`JSR`-target heuristic, not from
reading the code. `$0F0C` is a *disk buffer* routine (it moves 8- and 16-byte runs between
`$0200`/`$0278` and `($29),Y`). Attribute routines by reading them, not by proximity.

### Land-mass phase — real entry at `$212A`

`BUILDING LAND MASSES` is printed at `$2123` by the screen-string routine `$0C1B` (`$29`/`$2A`
= screen destination, A/Y = string pointer). Generation begins immediately after:

```text
$2146  JSR $0AE2      ; random byte
$214D  JSR $0A6E      ; divide by $5A (90)  -> 0..2
$2150  STA $57        ; keep the quotient
$2154  JSR $0A51      ; multiply by 7       -> 0, 7, or 14
$2157  TAX
$2158  LDA $2286,X    ; index a table of 7-byte records
$215B  CMP #$FE       ; $FE is the table sentinel
$215F  JMP $280A      ; ... on sentinel
```

The table at `$2286` holds exactly three records before the sentinel:

```text
00 00 02 02 00 02 FE
00 FF 01 02 00 02 FE
00 00 01 02 00 06 FE
```

Small magnitudes with an `FF` that reads as -1 — consistent with signed direction or motion
vectors, which is what a plate tectonics model would start from. Working hypothesis: the
generator picks one of three plate configurations at random. **Not yet confirmed** — decoding
these six fields is the next task.

### Arithmetic helpers (ported)

Neither is RNG; both are general-purpose and used throughout generation.

| Routine | Operation                                                            |
| :------ | :------------------------------------------------------------------- |
| `$0A51` | 8x8 to 16-bit multiply, shift-and-add. `A x Y`, low in A, high in Y  |
| `$0A6E` | 16-by-8 restoring divide. `(Y:A) / X`, quotient in A, remainder in Y |

`Arithmetic.swift` transcribes both literally, **including a wart**: the divide's inner
`ROL A` discards its carry out, so when the dividend's high byte is greater than or equal to
the divisor the quotient overflows and the result is garbage. `game3` avoids this by keeping
high bytes small. Do not "fix" it — downstream code may depend on the exact results.

Note `$2D23` is invoked twice with different parameter blocks (`$2D70`, `$2D74`, `$2DA6`) — a
parameterized terrain-scatter pass, worth identifying early since it likely covers several of
the manual's "geological principles".

The manual describes this code as running a plate tectonics model (mountain ranges where
plates collide, plus secondary ranges) and a cultural diffusion model (pueblo dwellers between
city-states and primitive agriculturalists).

**Verification plan:** the World Maker's output is a whole disk. Run the original under VICE
to produce a map disk, run the Swift port with the same seed, and compare sector-for-sector.
`BLANKMAP.D64` is the first reference output.

### Solved: the RNG and the seed

There are only six SID accesses in `game3`. Setup at `$208E` is the textbook noise-RNG rig:
`$D40E`/`$D40F` = `$FF` (voice 3 frequency), `$D412` = `$80` (noise waveform).

**Seeding** at `$20CB`, immediately after `CLI`:

```text
$20CB  LDA $D41B   ; oscillator 3 output
$20CE  STA $CD
$20D0  LDA $D41B
$20D3  STA $CF
```

So the seed is **16 bits, held in zero page `$CD` (high) and `$CF` (low)**.

**The generator** is a 16-bit LFSR at `$0AE2` (also reachable via `JMP` at `$0B10`), shifted 8
times per call, returning `$CF` in A. `$CE` is scratch, `$CC` saves X:

```text
$0AE2  STX $CC / LDX #$08
$0AE6  CLC / LDA $CD / ROL A x4 / AND #$02 / STA $CE   ; tap 1
       LDA $CF / AND #$02 / CLC / EOR $CE              ; tap 2, XOR
       BEQ +  / SEC
     + ROL $CF / ROL $CD                               ; 16-bit shift through carry
       DEX / BNE loop
       LDA $CD / ORA $CF / BNE + / INC $CD             ; escape all-zero state
     + LDX $CC / LDA $CF / CLC / RTS
```

Transcribe this **literally** into Swift rather than "simplifying" it. `ROL A` is a 9-bit
rotate through carry, and the tap positions after four rotations are easy to get subtly wrong
by reasoning about them instead of emulating them.

### The wrinkle: the IRQ stirs entropy continuously

The raster IRQ handler at `$23FC` perturbs the LFSR state on **every interrupt**:

```text
$23FC  PHA / TYA / PHA / TXA / PHA
$2401  LDA #$01 / STA $D019     ; ack raster IRQ
$2406  LDA $D41B                ; live oscillator read
$2409  ADC $CD
$240B  STA $CD                  ; stir the high byte
$240D  INC $BD / BNE / INC $BE  ; frame counter
```

So the generator is deterministic *between* interrupts but continuously reseeded by free-
running hardware. Consequences:

- No specific historical run was ever reproducible, even on real hardware — world generation
  depended on interrupt timing. Reproducing a *particular* 1984 world is not a lost capability.
- **For the port:** expose a clean 16-bit seed, use the exact LFSR above, and simply omit the
  IRQ stir. Fully deterministic, and faithful to the algorithm.
- **For differential testing:** neutralize the stir in the original. NOP the seven bytes at
  `$2406`-`$240C` (`LDA $D41B` / `ADC $CD` / `STA $CD`), then write a known seed to `$CD`/`$CF`
  after startup. The run becomes fully deterministic and sector-for-sector comparison against
  the Swift port works.

### Done: RNG ported and verified

`SevenCitiesCore/Sources/SevenCitiesCore/WorldMakerRNG.swift` is a literal transcription.
`tools/rng_reference.py` executes the original routine in VICE across 5 seeds x 64 values and
writes a fixture; the Swift tests assert an exact match on both output and internal state.
Confirmed non-vacuous by mutation: changing the four `ROL A` rotates to three produces 949
recorded failures.

### Headless World Maker (works — `tools/wm_trace.py`)

The World Maker can be run end to end with **no UI interaction at all**: poke `game3` to
`$0800`, patch out its keyboard wait, and `SYS $1E99`. It formats the attached disk and
generates a complete world. This is far more reliable than driving menus.

The wait it blocks on is at `$1F7C`, and it polls the **keyboard matrix directly**:

```text
$1F7C  LDX #$FF / STX $DC02      ; DDRA = outputs
$1F82  STX $DC00                 ; select row 0
$1F85  LDA $DC01 / AND #$08      ; bit 3 = F7
$1F8A  BNE $1F7C                 ; spin while not pressed
```

Patch `$1F8A` (the `BNE`) to `EA EA` and it falls straight through.

Structure learned from running it:

- The pipeline `$0E20` is called **twice**, from `$0DB5` and `$0DC3`, each followed by
  `JSR $0F47`. The world is generated in two passes.
- **The map is assembled on disk, not in RAM.** 104 KB will not fit in 64 KB. RAM barely
  changes across phase boundaries (~141 bytes), which is why generation takes 18 minutes —
  it is streaming sectors the whole time.
- Consequently, snapshotting RAM *or* the disk image at phase boundaries reveals nothing
  useful: disk writes only happen after a complete `$0E20` pass, so intra-pipeline snapshots
  are identical.
- The land-mass phase writes predominantly `$00` and `$BB`. Rendering a generated map with
  `$00` as ocean and `$BB` as land shows clear ocean/land separation — the first genuinely
  map-like image — but land appears as long thin horizontal streaks, so the row stride is
  wrong.

**A binarized stride sweep over land cells (`$BB`) found no peak at any width from 64 to
6000** — monotonic decay only. That is the second failed statistical attack on the layout.
Do not try a third.

**Next instrument:** checkpoint the sector-write routine `$0F47` and log `(track, sector,
payload)` in write order. That gives ground truth for the layout with no inference: exactly
which bytes land in which sector, and in what order rows are produced.

### Harness gotchas (all cost real time — do not rediscover)

- **A leftover checkpoint leaves the CPU paused.** Every later step then silently does
  nothing, and the failure looks like "the machine never booted". Clear checkpoints first, and
  note the delete parameter is `checkpoint_num`, not `number`.
- **Setting `PC` via the debugger and resuming does not stick.** Control has to be transferred
  by the machine itself. The harness pokes a small driver into memory and runs it with `SYS`.
- **The KERNAL uses `$CC`-`$CF` for cursor blink** — exactly the LFSR's zero page. Its IRQ
  corrupts the state between calls, so the driver runs under `SEI`.
- **Poll for the BASIC `READY.` prompt** (screen codes `18 5 1 4 25 46` at `$0400`) before
  typing; a `SYS` sent earlier is dropped.

## Driving VICE (hard-won, reusable)

- **Keys can stick down, and poison everything afterwards.** `vice_keyboard_matrix` with
  `hold_frames` did not always auto-release; F7 was held for a long stretch of one session
  (visible as CIA1 `port_b` = `$F7`, bit 3 low), which made menu behavior erratic and
  unrepeatable — the same call launching World Maker once and doing nothing the next time.
  Check `vice_cia_get_state` `port_b` = `$FF` before trusting any input result, and release
  explicitly with both `vice_keyboard_key_release` and `vice_keyboard_matrix pressed=False`.
- **Menus read the KERNAL buffer; use `vice_keyboard_key_press` for them.** An earlier note
  here claimed matrix input was always required. That was over-generalized from in-game
  behavior. `key_press` is what reliably drives the title menu and World Maker prompts.
- **Joystick injection never worked on the "press button to continue" screens.** Neither
  `vice_joystick_set` nor `vice_joystick_tap` on either port, nor Space/Return, advanced them.
  Unresolved. Prefer driving code directly (below) over automating the game's UI.
- **Prefer poke-and-`SYS` over UI automation.** Loading a routine into memory and calling it
  has worked every time; screen-synced menu driving has been fragile and slow. The RNG and
  arithmetic harnesses both use poke-and-`SYS`.
- **Turn warp OFF when timing input, ON otherwise.** Loads take a long time in real time, but
  warp compresses the menus' key-poll window so far that presses land between polls.
- **Sync to screen state rather than sleeping.** Screenshot-poll and pixel-diff against a
  saved template of the target screen, then fire the key on match. Blind delays fail because
  the attract loop only polls keys while its menu text is displayed. This same technique is
  what the differential harness will need for scripted input traces.
- `vice_machine_config_set` wants `resources` as an object; the MCP schema declares it a
  string, so the typed tool call fails. Use `tools/v.py` for that one.

## Solved: map layout

The answer was in the World Maker's write path, not in any statistic. Three
separate things had to be right, and the first two attempts got each of them
wrong.

**1. Sectors are 16x16 blocks.** The assembly loop at `$0F54` gathers 16 bytes
from each of 16 source rows spaced `$80` apart.

**2. Blocks tile 8 per row, not 16.** The source row stride is `$80` = 128
tiles, and a block is 16 wide, so one memory row spans 128 / 16 = **8 blocks**.
Rendering at 16 per row places two consecutive map rows side by side and
produces a visibly doubled map — two North Americas, two South Americas.

**3. A sector is not row-major inside the block.** Tracing X through the loop:
each outer pass writes 8 tiles to `$0200+8i` and 8 more to `$0278+8i+8` ==
`$0280+8i`. So the sector splits as

```text
bytes $00-$7F : left 8 columns of all 16 rows
bytes $80-$FF : right 8 columns of all 16 rows
```

Reading it row-major scrambles the columns inside every block — the map is
roughly recognizable but visibly corrupted.

**Buffer address**, from `$0EE4` with `$62` = 7:

```text
source = $5700 + (hi_nibble($0C) * 2048) + (lo_nibble($0C) * 2)
```

so the in-RAM map buffer is about 26 KB at `$5700`.

**Geometry.** The map proper is **128 x 400 tiles**, occupying block-rows 24-48
(tile rows 384-783). Both `7CITIES2.D64` and an independently generated world
crop to exactly the same geometry, which is a strong consistency check. Regions
above and below are padding (`$01`), and the historical disk carries an extra
non-terrain region above the map that must be excluded by taking the longest
*contiguous* run of terrain rows, not the min-to-max span.

**Horizontal offset.** The sector stream starts one block *before* the map's
true left edge, so the assembled image comes out shifted right and the eastern
bulge of South America wraps around to the left. Roll left by 1 block (16
tiles) to correct it. Chosen objectively, not by eye: at a 1-block roll the
wrap seam cuts through **zero** land tiles and column 0 is entirely ocean,
while all seven other offsets slice a continent in half.

`tools/map_preview.py` renders any map disk. The historical map comes out as an
unmistakable Americas — Great Lakes, Florida, Gulf of Mexico, the Caribbean
chain, Central America, and South America with the Amazon basin, the Andes and
the Brazilian bulge.

**Lesson, learned expensively:** two statistical attacks on this layout failed
completely; reading the code that writes the format solved it. Instrument the
producer, do not infer from the product.

## Solved: tiles are nibbles — the map is 256 wide

Each byte holds **two horizontally adjacent tiles, high nibble first**. This is
why `$0EE4` multiplies the low nibble by 2, and why the byte values pair up the
way they do: `$BB` is two land tiles, `$00` two ocean, and `$B0` / `$0B` are
land+ocean — a coastline, nibble-swapped for which side the water is on.

So the finished map is **256 x 400 tiles**, not 128 x 400. Rendering bytes as
single tiles still produced a recognizable map because a 2:1 horizontal squash
of the Americas still looks like the Americas — which is exactly why it went
unnoticed for several passes.

### Cell addressing (confirmed from `$0FAE` / `$0FEA` / `$0FD3`)

```text
cell(col, row) = $5700 + row * 128 + (col >> 1)
even col -> high nibble, odd col -> low nibble
mask table at $0FD1 = $F0, $0F
```

`$0FEA` reads a cell (shifting the high nibble down), `$0FD3` read-modify-writes
one nibble. So the map is **256 x 400 tiles**, 16 possible values per tile.

### Terrain nibbles

Established three ways: diffing the map buffer across generation phases, the
spatial signature of each value, and the 16 `JSR $0FD3` write sites. Then
cross-checked against an independent community dump of the historical map,
which agrees on every continent, island chain, river course and mountain range.

| Nibble | Meaning              | Evidence                                        |
| :----: | :------------------- | :---------------------------------------------- |
| `0`    | ocean                | land-mass phase writes it; 59% of the map       |
| `1`    | shelf / shallows     | rings every coast; terrain phase's biggest write |
| `2`    | sparse coastal fringe | thin, hugs coastlines                          |
| `3`,`4` | rare special sites  | 14 and 19 cells total; unidentified             |
| `5`-`A` | **rivers**          | dendritic networks matching Mississippi, Amazon, Parana |
| `B`    | plain / grassland    | land-mass phase writes it; 21% of the map       |
| `C`    | forest               | eastern North America and the Amazon basin      |
| `D`    | mountain             | continuous Rockies/Andes spine — unmistakable   |
| `E`    | unidentified terrain | clumped, 29% self-adjacent, neighbours plain and forest, not mountains; swamp or desert more likely than jungle |
| `F`    | **native village**   | isolated single cells; 353 of them              |

Two things worth care:

- **`F` is not a scratch marker.** `$2D23` does use `$0F` as a temporary fill
  value, but it unfills it (`$0F` -> `$00`) on the second call, so surviving
  `F` cells are villages. This matches the reference dump's red squares and the
  village phase writing `$BF`/`$FB`/`$FC`/`$CF`.
- **Rivers are connection masks, not flow direction.** Each of `5`-`A` encodes
  which *two* neighbours the tile links to — exactly the six ways to choose 2
  directions from 4, each measured at a clean ~49/49 split:

  | `5` W-E | `8` N-S | `6` N-W | `7` S-W | `9` N-E | `A` S-E |
  | :------ | :------ | :------ | :------ | :------ | :------ |

  Two-way links only, which is why junctions get their own value (`4`).

Write sites, for porting the terrain phase: `$2AAB`(2) `$2B8C`(3) `$2C28`(B)
`$2CE5`(2) `$2CFE`(1) `$2D1B`(1) `$2D75`(F scratch) `$2E0E`(B) `$2EAB`(C)
`$2F47`(D) `$2F7D`(E) `$3115`(D) `$327C`(B) `$3E4B`(E), plus two
register-sourced writes at `$332C` and `$343E`.

## Manual (`docs/Seven Cities of Gold.pdf`)

21 scanned pages, 20 JPEGs, no text layer, no embedded fonts. Requires `poppler` to render.
Manual pages 1-9 map to PDF pages 7-15.

Facts worth encoding:

- One screen is 120 miles per side on the exploration surface, 960 miles per side on maps —
  an 8:1 zoom ratio.
- Win condition: overall rating of at least 50% by 1540 to reach Viceroy.
- The World Maker runs a plate tectonics model (mountain ranges where plates collide,
  secondary ranges) plus a cultural diffusion model (pueblo dwellers appear between
  city-states and primitive agriculturalists). This is `game3`, 18 KB of pure code.
- Copyright page: software (c) 1984 Ozark Softscape, published by Electronic Arts.

**Gap:** post-1540 play uses a reference card that shipped with the disk. It is not in the
PDF, so those bindings must come from the disassembly unless a scan turns up.

## Toolchain

| Tool             | Status | Notes                                                     |
| :--------------- | :----: | :-------------------------------------------------------- |
| poppler          |   ok   | `pdftoppm`; required to read the manual                   |
| cc65             |   ok   | `da65` cracked the loader; `ca65`/`ld65` for round-trips  |
| vice-mcp         |   ok   | v3.11.0 macOS arm64 GUI build; **not** Homebrew VICE      |
| Ghidra           |  skip  | vice-mcp's trace/checkpoint tools cover this better       |

vice-mcp is a fork of VICE with the MCP server compiled in, so Homebrew's VICE will not work.
Start it with `x64sc -mcpserver` (listens on `127.0.0.1:6510`), registered as `vice`.

`tools/v.py` drives the server over plain JSON-RPC when the MCP tool schemas are not loaded in
the session — no handshake or session ID needed.

## Scripts in `tools/`

| File                    | Purpose                                                             |
| :---------------------- | :------------------------------------------------------------------ |
| `d64.py`                | D64 reader: directory, file chains, BAM, raw sectors                |
| `c64gfx.py`             | Render C64 hires bitmaps and charsets to PNG                        |
| `v.py`                  | JSON-RPC client for the vice-mcp HTTP server                        |
| `dis6502.py`            | Recursive-descent 6502 disassembler; separates code from data       |
| `loader-c000.disasm.s`  | `da65` output for the `$C000` fastloader (partly data-misaligned)   |

Prefer `dis6502.py` over `da65` for these binaries. It follows control flow from entry points,
so code and data are separated by reachability instead of guesswork — `da65` misaligns badly
where data is interleaved with code. Usage:

```bash
python3 tools/dis6502.py local/game3.bin 0x0800 0x1E99,0x0E20 0x0E00-0x0E90
```

The `local/` directory holds disassembly listings and extracted binaries. They are derived
from copyrighted code — keep them out of any published repo.

Correct raw-stream extraction, given the loader rule:

```python
nsec = min(20, sectors_per_track(t))   # loader never reads sector 20
```

## Proof of concept — Milestone 0 (revised)

Originally "the coastline test": decode the historical map and render it. That is now parked
behind the unsolved cell encoding.

**Current target: port the World Maker.** It is self-contained, needs no knowledge of the map
encoding, and produces worlds rather than consuming one. Verification is exact rather than a
judgment call: generate a world with the Swift port and the original at the same seed, then
compare the resulting disk images sector-for-sector.

The coastline test still stands as the later milestone for the historical map.

## Verification strategy for the full port

Differential testing against VICE. Drive the original with a scripted input trace via
`vice_joystick_set`, snapshot game-state RAM each turn with `vice_memory_read`, and assert
`SevenCitiesCore` matches byte-for-byte. That turns "did we get the rules right" from an
opinion into a failing test.

## Open: does one map cell equal one drawn tile?

Unresolved, and it matters for the renderer's design.

Each cell is one 4-bit terrain code, and the community dump draws one glyph per
cell. But the manual's scale figures do not reconcile with a 1:1 tilemap. An
exploration screen is **120 miles per side**. At ~40 cells across that is 3
miles per cell, making the whole 256x400 map only ~768 x 1,200 miles — far too
small for the Americas at roughly 9,000 miles north to south. Working the other
way, 400 cells over 9,000 miles is ~22 miles per cell, which puts only ~5 cells
across a 120-mile screen.

Three possibilities, undecided:

- the exploration view draws each cell as a large multi-character tile
- the game generates finer detail procedurally from the coarse map
- the mile figures are flavor rather than geometry

The renderer is in `game.prg`, the 36 KB main binary, which is still completely
unexamined — all work so far has been in `game3`. Settle this before designing
the SpriteKit renderer: a procedural-detail surface is a very different job
from a straight tilemap.
