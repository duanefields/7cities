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

- **Use `vice_keyboard_matrix`, not `vice_keyboard_key_press`.** The game scans the keyboard
  matrix directly and never reads the KERNAL buffer, so buffer-level input is invisible to it.
- **Turn warp OFF when timing input, ON otherwise.** Loads take a long time in real time, but
  warp compresses the menus' key-poll window so far that presses land between polls.
- **Sync to screen state rather than sleeping.** Screenshot-poll and pixel-diff against a
  saved template of the target screen, then fire the key on match. Blind delays fail because
  the attract loop only polls keys while its menu text is displayed. This same technique is
  what the differential harness will need for scripted input traces.
- `vice_machine_config_set` wants `resources` as an object; the MCP schema declares it a
  string, so the typed tool call fails. Use `tools/v.py` for that one.

## Open: map cell encoding

What is known:

- Map row = 256 bytes = exactly one sector. Sharp autocorrelation peak at W=256 once sector
  order was corrected; the nibble view peaks at 512, the same layout seen twice.
- Content is on tracks 19-33. Tracks 14-18 and 34-35 are uniform fill. 406 rows in the
  region, 171 with real data.
- Byte histogram: `$00` 35.8%, `$01` 30.8%, `$BB` 7.4%, `$11` 2.8%, `$80` 2.7%, then `$CB`,
  `$BC`, `$CC`, `$DB`, `$DD`.

Ruled out, each producing structure but nothing map-like:

- byte-per-cell tilemap
- nibble-per-cell tilemap (solid `$01` renders as alternating stripes, so `$01` is one cell)
- RLE with high bit as count (5/171 rows decode to a valid length — chance level)
- RLE with low byte as count (18/171 — chance level)
- column-major (sector = column)

Structure learned from diffing `BLANKMAP.D64` against `7CITIES2.D64`. Uniform sectors are
exactly `$4B` followed by 255 copies of `$01`; content sectors carry a different leading byte
and payloads confined to distinct value bands. Laid out in loader order, all 431 sectors fall
into zones:

| Rows    | Content                                        |
| :------ | :--------------------------------------------- |
| 0-151   | uniform `$01`                                  |
| 152-167 | all high-bit values (`$80`-`$AD`)              |
| 168-171 | high entropy, 33-47 distinct values per sector |
| 172-191 | uniform `$01`                                  |
| 192-397 | the varied main region                         |
| 398-430 | uniform `$01`                                  |

That reads as **several stacked planes, not one grid**, which explains why every single-grid
hypothesis produced structure but never a coastline. The manual's 8:1 exploration-to-map zoom
ratio implies at least two terrain representations; the 16 high-bit rows plus 4 high-entropy
rows are plausibly a separate table (villages, or the overview map).

Note the leading byte is *not* a constant header — across the disk it takes many values from
the same alphabet as the map data, so "1-byte header + 255-byte payload" is not established.

**Next step when this is picked up again:** get in-game (the sync technique above works; the
game program loads and reaches "THE BEGINNING"), then screenshot the rendered map while
reading the map buffer out of RAM. Correlating the two settles the encoding directly. Chasing
it statistically was tried at length and did not pay off.

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
