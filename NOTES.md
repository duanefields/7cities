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
| `game`      | `$0800-$94FF`  |  36,096 | Main program, **enciphered** — solved, see below |
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

## Solved: font (exact)

96 glyphs, 8x8, in **ASCII order** starting with space — not PETSCII order, which is why the
game's text tables index it as `character = ASCII - $20`.

**Offset 4713 (`$1269`)** of the raw stream from disk 1 tracks 1-10, ending at 5481.
Ground-truthed by matching against a charset dumped from the running game, not by scoring —
the scoring heuristic had 4713 and 4714 tied and picked the wrong one.
`tools/extract_font.py` pulls it to `local/font.png` and `local/font.json`, and verifies the
offset rather than trusting it: glyph 0 must be blank and all 26 letters must have ink in rows
1-6 with a blank row 7. Currently 26/26.

Glyph indices 64-95 are not ASCII letters but custom symbols — likely UI or terrain icons,
not yet identified.

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

**Correction: these are not 7-byte records, and the `FF` is not -1.** The earlier reading came
from noticing the `x7` stride and assuming the stride was the record size. It is not. Following
the actual read order settles it:

```text
$2158  LDA $2286,X / CMP #$FE / BEQ done
$2162  STA $54     ; field 1
$2164  INX / LDA $2286,X / STA $43    ; field 2
$216A  INX / LDA $2286,X / STA $55    ; field 3
$2170  INX / STX $56                  ; remember where we are
...
$227A  LDX $56 / JMP $2158            ; and read the *next* three
```

So the table is three **command sequences of 3-byte commands**, each terminated by `$FE`. The
`x7` only picks which sequence to start at, and each sequence happens to be two commands plus
the sentinel. Parsed that way all three land exactly on `$FE`, which a wrong stride would not do
three times out of three:

| Seq | Command 1        | Command 2        |
| :-- | :--------------- | :--------------- |
| 0   | `00 00 02`       | `02 00 02`       |
| 1   | `00 FF 01`       | `02 00 02`       |
| 2   | `00 00 01`       | `02 00 06`       |

The three fields are **(size class, flags, count)**:

- **size class** (`$54`) is only tested for zero (`$2175`): 0 selects radius `$46` = 70, anything
  else selects `$0A` = 10. So class 0 is a continent and class 2 is an island.
- **flags** (`$43`) is a bitfield read with `BIT`, never as a number — which is what rules out
  the signed-vector reading. Only bit 7 is used, at `$21B0` and `$2231`.
- **count** (`$55`) is the repeat count, decremented at `$2270`.

**The command table is only the first stage of the phase.** `$215F JMP $280A` fires when the
sentinel is reached, and `$280A` is not the end of anything — it starts a second wave:

```text
$280A  LDA #$02 / LDX #$08 / LDY $57 / CPY #$02 / BNE +   ; count = random(2..8)
$2816  LDA #$08 / LDX #$0D                                ; config 2: random(8..13)
$2818  JSR $22B4 / STA $55 / STA $54
$2824  $21 = $0A, then $22F7 at radius 5, then radius 3   ; small islands
$2837  reject y in $C3..$DB (195..218)                    ; a latitude exclusion band
$285E  record into $038C,($67) or $03B4,($68)             ; two lists, split at row 219
$2894  end of phase
```

So the phase adds a further 2-7 radius-3 islands (8-12 for configuration 2) after the command
table finishes, and files their positions into **two** separate tables depending on whether the
row is below 219. Measured, at seed `$1234`:

| Config | Blobs at `$280A` | Blobs at `$2894` |
| :----- | ---------------: | ---------------: |
| 0      | 4                | 11               |
| 1      | 4                | 9                |
| 2      | 8                | 16               |

**This does not disturb the command-table reading** — the counts below are measured exactly at
`$280A`, where the table finishes, and they are what the table predicts. But an earlier version of
this file, and the tooling's `LANDMASS_DONE` constant, treated `$280A` as the end of the phase. It
is not. The error was the same shape as reading `$1900`'s `JMP` as that routine's purpose: finding
a jump and assuming where it goes, instead of reading the target. The constants are now
`TABLE_STAGE_DONE` and `PHASE_DONE`, and the fixture captures both.

Which makes the three world configurations, **at the end of the command-table stage**:

| Seq | Reading                                             |
| :-- | :-------------------------------------------------- |
| 0   | 2 continents + 2 islands                            |
| 1   | 1 continent (flag bit 7 set) + 2 islands            |
| 2   | 1 continent + 6 islands, islands in a latitude band |

### Verified against the original (`tools/wm_config.py`)

This is a falsifiable prediction, so it was tested rather than left as a reading. The tool patches
the ten bytes at `$2146` that draw the configuration (`LDA #config` followed by `NOP`s, leaving
the `STA $57` in place), runs the land-mass phase headlessly to `$280A`, and flood-fills the land
mask. All three configurations produce exactly what the table predicts:

| Config | Predicted | Built | Blob areas                             |
| :----- | :-------- | :---- | :------------------------------------- |
| 0      | 2 + 2     | 2 + 2 | 17353, 16603, 427, 381                 |
| 1      | 1 + 2     | 1 + 2 | 27756, 438, 407                        |
| 2      | 1 + 6     | 1 + 6 | 15346, 519, 508, 456, 422, 417, 387    |

Config 1 is the interesting one, and it is the strongest single piece of evidence that the flags
byte is a bitfield and not a signed vector: its command has **count 1** and yet it always builds
**two** continents. That is flag bit 7 doing exactly what `$2231` says it does — place a second
landmass at `x - $4E`, `y + size * 2 + size / 8`.

**Whether the pair merges is seed-dependent**, so count the land, not the blobs. One seed gave a
single 27,756-cell mass — about twice a normal continent, rendering as two continents touching
corner to corner — while seed `$1234` leaves them separate, for four masses rather than three.
The fixed offset puts them adjacent; the coastline walker decides whether they actually touch.

Config 2's islands all land in the lower half, matching the `$2208` latitude clamp. Its blob count
comes out at 8 rather than the expected 7 because the walker sheds the occasional detached speck;
the `blobs()` helper counts every connected region, including one-cell ones.

**Force the configuration by patching, not by poking a register.** Setting `A` at a checkpoint on
`$2150` looks surgical and silently does not work: `$57` reads back as 1 whatever is written,
because the phase is entered more than once and the checkpoint catches a later pass. Three runs
were read wrong before the patched-constant approach settled it. Worse, the first pass of the
experiment appeared to "work" — three runs returned the three predicted shapes, just permuted —
which is what an uncontrolled random draw looks like when the sample is this small. Getting all
three distinct by chance has probability 6/27, about 22%.

Sequence 1's flag bit 7 makes `$2231` test a **second position** offset from the first before
accepting either — `$22`-`$24` are saved to `$47`-`$49`, shifted by `$4E` in x and by
`size * 2 + size / 8` in y, retested, then restored. That is a paired landmass: two continents
placed as a unit.

**The pair's horizontal offset is drawn, not fixed** (an earlier note here said fixed). `$4E` comes
from `$2186`: `$0ACB($0F) + 1`, redrawn while it lands on 1, where `$0F` is `radius * 5 / 7`. Only
the vertical offset, `2 * radius + radius / 8`, is constant. Measured values of `$4E` include 48
and 6 for radius 70.

Two draws happen at `$2186` and `$2193` **regardless of whether their results are used**: `$4E` is
overwritten with `$FF` at `$21B4` when the command is not paired, and the `$B1`/`$B2` coin flip is
overwritten at `$21A8` for islands. Both still advance the LFSR, so a port that skips them
desynchronizes every later draw.

The bounds differ for a paired command too, in two places that are easy to miss — `xLower` becomes
`$4E + radius` and `yUpper` becomes `$0185 - (3 * radius + radius / 8)`, reserving room to the left
and below for the partner. `LandMassPhase.bounds` models both; an earlier version of that code
modeled neither.

`$0ACB` is worth distinguishing from `$22B4`: it takes **one** draw and reduces it modulo the limit
by repeated subtraction, self-modifying the operand of its own `CMP` and `SBC` at `$0AD9`, and
returns 0 for a limit below 2. `$22B4` rejects and redraws instead. Different routines, different
LFSR consumption, both used in the same loop. Sequence 2 is special-cased at `$2208` (`LDA $57 / CMP #$02`)
to clamp its continent's y range to 110..220 instead of the full map.

### Placement

Rejection sampling, not a growth model. Per landmass:

```text
x        = random($21 .. $FE - $21)          ; $2220, via $22B4
y        = random($21 + 2 .. $0185 - $21)    ; $2229, via $247B, 16-bit
if $22F7 rejects: retry, up to 256 times ($52 wraps at $2281)
```

`$22B4` is `random(lo ..< hi)` by rejection, and it is **self-modifying**: `STA $22E8` and
`STX $22EC` patch the operands of the two `CMP` instructions at `$22E7` and `$22EB`. Read as
written, those look like `CMP #$FF` twice; they are the bounds. `$247B` is the same idea over 16
bits for y. Both inline the LFSR from `$0AE2` rather than calling it.

`$22F7` is the accept/reject test, and it is **not an area test** despite sitting where one would
be. It samples a **cross** through the bounding box: three horizontal lines at rows `y - size`,
`y` and `y + size` scanning columns left to right, then three vertical lines at columns
`x - size`, `x` and `x + size` scanning top to bottom. Any sampled cell already set rejects the
position. Two landmasses can therefore overlap substantially without either noticing — a property
of the original's output, not something to fix.

Ported as `LandMassPhase.isClear`, verified against the original across 18 positions
(`tools/areatest_reference.py`). Three things bite when transcribing it:

- **Both scans are do-while**, not while. The body always runs once, even when the bounds are
  already crossed, and `INC` before `BCC` means neither scan samples its far edge. Writing them
  as `while col <= right` is wrong twice over.
- **The bounds clamp asymmetrically.** The right edge becomes `$FE` only if `x + size` carries out
  of a byte; the bottom is clamped to `$8E` only once `y + size` crosses 256, putting the
  effective floor at row 398.
- **`$62` is not set by `$22F7`.** It holds the shift count (5) that turns a row number into an
  address, and the *phase* sets it at `$2130`. A harness that calls `$22F7` directly must set it
  too — without it the address arithmetic is garbage, which is invisible against an all-zero or
  near-solid mask and wrong everywhere else.

The last of those wasted a fixture. A first attempt used a uniformly random 12.5%-density mask and
came back 32 cases, **every one blocked** — which is what a cross sampling ~840 cells will always
do at any plausible density, and which no correct-versus-broken port could be distinguished by. A
fixture with only one outcome is not a test. `LandMassPhaseTests` now asserts the fixture contains
both, so that failure cannot recur silently.

### `$B0` is the radius; `$21` is scratch

Both are written together at `$217B` (`STX $21 / STX $B0`), which makes them look interchangeable.
They are not. Captured at every registration across 9 seed/config pairs, `$B0` is **always** exactly
`$46` or `$0A`, while `$21` drifts — 71, 82, 75, 62 all appear. Use `$B0` wherever the command's
nominal radius is meant.

`$22F7` reads `$21`, not `$B0`, so the placement test runs at whatever `$21` holds.

**Resolved: there is no drift. It was a measurement artifact.** Traced in the interpreter, `$21`
equals `$B0` at *every* registration across seeds `$1234`, `$BEEF` and `$0001` — never 71. The
emulator capture that produced the 71 had overshot `$1B5F`, because VICE's checkpoints halt late,
into code that had already modified `$21`. The program was never doing what the fixture said.

Two consequences. The `radius` field in `placement_reference.json` is **unreliable** — it records
`$21` at an imprecise moment; use `b0`, which the Swift tests already do, so they are unaffected.
And any measurement that reads memory at a mid-phase address is suspect in the same way: stage
boundaries are safe because writing has stopped, arbitrary addresses are not.

The search below is kept because the reasoning stands even though the premise was false, and
because the technique — scan for writers, cross-check against the disassembly, then falsify the
obvious hypothesis — is what should be repeated. What should *not* be repeated is trusting a
mid-phase emulator read in the first place:

- Scanning the binary for direct zero-page writes (`STA`/`STX`/`STY`/`INC`/`DEC` with operand `$21`)
  finds 12, all confirmed against the disassembly. **None lies between `$2183` and `$226A`.**
- That scan is **incomplete by construction**: indexed stores are invisible to it, because their
  operand byte is the base, not the address. `$1B59 STA $1F,X` reaches `$21` at index 2, and
  `$264A`, `$278A`, `$2EFC` and `$4A1E` are all `STA $21,X`. None of those is in the span either.
- The walker was the obvious suspect, since `$17A1` and `$187E` write `$21` and `$1866` also
  registers landmasses. **Falsified:** `$1866` fires zero times in configuration 0 for seeds
  `$1234`, `$BEEF` and `$0001`, yet two of those show a 71.
- Bisecting with exec checkpoints proved unreliable twice — see the harness notes — so the paired
  samples cannot be trusted to come from one iteration.

And `$21` genuinely does differ from `$B0` *inside* the walker, which is what made the false
reading plausible: see below, where it turns out to be the shape mechanism rather than corruption.

### Two call sites register landmasses, and the second is inside the walker

`$1B5F` is reached from `$226A` in the placement loop and from `$1866` inside the walker. Counting
hits separates them:

| Config | `$226A` | `$1866` |
| :----- | ------: | ------: |
| 0      | 4       | 0       |
| 1      | 3       | 1       |

So a paired command registers **once** from the placement loop, and its partner is registered later
from inside the walker — which is why configuration 1 yields four registrations from three commands,
and why that fourth entry carries a drifted `$21` (82) alongside `$B0` = 70.

`$1B5F`/`$1BD9` is **not** the draw, despite sitting where a draw would. It appends
`(y, size, class)` to a registry at `$033C` (the cassette buffer) indexed by `$64`, and bumps
`$A9` for each island. Note the copy loop at `$1BE1` runs **once**, not twice: `LDX #$01` then
`DEX / BNE` exits immediately, so it stores `$22` and never `$21`. Later phases — rivers, villages — read that registry. `$23D3` is the
routine that actually fills, via the rasterizer at `$15AD`, with shape parameters computed by
`$1731` from the radius (`$0F` = `size * 5/7`, `$13` = `size * 3/8`, `$12` = `size * 1.44`, plus
reciprocals `$10` and `$11`). `$15AD` itself is not yet read.

### Two buffers, both based at `$5700`

The generator uses two different addressings of the same base, and confusing them would wreck a
port:

| Helper  | Shift | Stride | Cell    | Mask table                          |
| :------ | :---- | :----- | :------ | :---------------------------------- |
| `$141C` | 5     | 32 B   | 1 bit   | `$13D3` = `80 40 20 10 08 04 02 01` |
| `$0FAE` | 7     | 128 B  | 4 bits  | `$0FD1` = `F0 0F`                   |

`$141C` builds a **land/water mask**, 32 bytes per row; `$142F` splits x into `x >> 3` for the
byte and `x & 7` for the mask index, and `$1B4E` is the bit test. The mask table bytes are
confirmed in the file. The two writes of `$80`/`$40` into `$13D3`/`$13D4` at `$0E3x` are
restores — a later phase clobbers the first two entries to mask two bits at a time.

`$0FAE` addresses **the map proper**: 128 bytes per row, one nibble per cell, 256 cells wide.
That is exactly the layout `MapDecoder` reads off a finished map disk, arrived at from the other
direction entirely, which is what makes the identification safe.

**The 1-bit reading is confirmed visually** (`tools/wm_landmask.py`). Dumping `$5700` at the end
of the land-mass phase and rendering it both ways is decisive: at 32 bytes per row it is
continents with jagged coastlines, and at 128 bytes per row the same data comes out as the same
continents repeated four times across, which is just the wrong stride. No statistics needed — and
on this project statistics have repeatedly supported conclusions that turned out to be wrong.

Land coverage varies with the configuration and matches the radii: about 15-18% for the
single-continent configs and about 30-34% for the two-continent one, against
`pi x 70^2 / (256 x 400)` = 15% per continent. Do not treat any single figure as *the* coverage
— the configuration is drawn at random unless it is patched.

At 400 rows the mask is 12,800 bytes (`$5700`-`$88FF`); the nibble map at 128 bytes per row would
be 51,200 and does not fit in a C64 at all. That is consistent with the note already in
`wm_trace.py` — the finished map is assembled **on disk**, not in RAM, which is why generation
takes about 18 minutes. `$2C14` bounds its row counter at `#$D0` = 208, and 208 x 128 = 26,624
fits at `$5700`-`$BEFF` under I/O, so 208 rows is most likely the band height. **Not yet
established:** whether the bands overwrite the mask in place and in which direction. Break on
writes to `$5700` during a headless run to settle it.

### `$15AD` is a coastline walker, not a blob fill

Worth saying before anyone tries to port it as "draw an ellipse and roughen it". `$15AD` is a
state machine:

- `$1A` is the state, 0..4, advanced at `$1631` and wound back at `$1646`.
- `$46` is a step counter that wraps at `#$C9` = 201, clearing `$2B` with it.
- Each step writes a **12-byte record** through `($02),Y` — nine bytes copied from `$2C`-`$34`,
  then `$14`, `$15`, `$1A`. So the coast is emitted as a trail of segments, not rasterized
  directly.
- `$1654` does `STX $1657`, where X is `$E6` or `$C6` — **`INC zp` and `DEC zp` opcodes**. It
  patches the instruction at `$1657` so the following loop walks `$15` toward `$B0` from either
  direction. Disassemble this region as data-plus-code or the listing lies to you.

The shape parameters from `$1731` feed this walker rather than any ellipse equation, which fits
the manual's claim of a geological model and fits the irregular coastlines the game actually
produces. Porting it means transcribing the state machine literally, self-modification included,
the same way the RNG and the divide were done.

#### What the walker is made of

Enough of the pieces are now identified to describe the mechanism:

| Routine | What it does                                                                 |
| :------ | :--------------------------------------------------------------------------- |
| `$289D` | `$29:$2A += $20` — advance the mask row pointer one row down                  |
| `$1B4C` | test the mask bit at column `$14` (`$1B4E` is the entry with X already set)   |
| `$13E0` | address a point **relative to the current heading**, negating by `$1A`        |
| `$1728` | `$13E0` then `ORA $13D3,X / STA ($29),Y` — **plot**, the only mask write      |
| `$16BB` | pointer to `$9100 + $46 * 12` — the walker's record ring                      |
| `$194A` | scanline flood fill of the traced outline, using `$9100` with a 3-byte stride  |
| `$1476` | evaluate a candidate step; carry set rejects it                               |
| `$1648` | span fill between `$15` and `$B0`, with the self-modified `INC`/`DEC`         |

So the walker has a position in `$22`/`$23:$24`, a heading in `$1A` (0-3, used by `$13E0` to rotate
its offsets), a step counter `$46` wrapping at 201, and a ring of 201 twelve-byte records at
`$9100`.

**The ring is an undo stack, not a trail, and the walker is a backtracking search.** `$16D1` reads
records back out: it decrements `$46` (wrapping `$FF` to `$C8` = 200), restores `$2C`-`$34`, `$14`,
`$15` and `$1A` from the record via the pointer `$16BB` computes, and retries through `$1A00`,
looping to `$16D1` again if that also fails. It discards its own return address with `PLA / PLA`
and exits by `JMP`, so it unwinds the caller too.

That matters for the port far more than the plotting does. A turtle can be transcribed routine by
routine; a backtracking search cannot be checked until enough of it exists to run, because a bug
anywhere shows up as "the walk went somewhere else". The undo record is the thing to get exactly
right: 12 bytes, being nine bytes of `$2C`-`$34` followed by `$14`, `$15` and `$1A`.

The steps themselves are a biased random walk. `$1555` and `$1583` each maybe-step one axis by one:
draw, compare against `$18`, then `$19`, then `$B1` (x) or `$B2` (y), and take a signed delta from
`$13DA`/`$13DE` indexed by `$1A & 1`. `EOR #$FE` flips the sign, turning `$01` into `$FF` and back,
which is how one table serves both directions.

`$178A` rewrites `$21` — `$21 = |$B3 + $15 / 2|`, then re-runs `$1731` to recompute the shape
parameters from it — so the radius genuinely changes during a walk. It runs often (2,158 times in
one measured phase). This is *not* an explanation for the `$21` drift seen at registration, since
the walker only runs after `$226A` and `$217B` resets `$21` each iteration, but it does explain why
`$21` and `$B0` disagree everywhere inside the walker.

`$1476` is where the coastline gets its shape. `$1D` (0-8) encodes one of nine directions, split
into an x delta from `$1D mod 3` and a y delta from `$1D div 3`, both looked up in the signed table
at `$13DA` (`01 FF 00 00 FF 01`, i.e. +1/-1/0). The candidate is then scored by a **3x3
neighborhood scan** — nine counters at `$35`, filled by `$1B4E` across and `$289D` down — and
rejected unless at least two neighbors are already land. That neighbor-count rule is what makes
coastlines jagged and self-similar instead of smooth.

`$13DA` overlaps the tail of the bit-mask table at `$13D3` (`80 40 20 10 08 04 02 01`), so the
`$01` at `$13DA` does double duty as both the last bit mask and the first delta. Do not "tidy"
that into two separate tables without checking; the overlap may be deliberate.

`$1666` temporarily patches `$229B`, `$229C` and `$22AF` — addresses **inside the data that
follows the `$2286` command table** — to `$0C`, then restores them to `$77`, `$EC`, `$49`. Those
bytes are operands of something, not part of the command table proper.

**Still open:** the walker's states and its output consumer, what `$2C14` is (a neighbor-scan
smoothing pass over `$14`/`$15`, not a disk writer), and the band structure.

### Do not scope this port by static reachability

Walking calls and branches from `$23D3` reaches **7,924 of the program's 8,152 instructions**, 97%
of `game3`, and the land-mass phase entry `$212A` reaches exactly the same set. That is not a
disassembly artifact. The path is real:

```text
$15AD ... -> $194A -> $1900 -> JMP $2473 -> JMP $20A3   (World Maker init)
      -> falls through to $212A -> ... -> $280A -> ... -> $0DB5 JSR $0E20
```

The edge is a **panic path**. `$1900` is an ordinary mask-walking routine, but its first four
instructions are a bounds guard on `$2A`, the high byte of the working row pointer:

```text
$1900  LDA $2A / CMP #$50 / BCS $1909     ; below the buffer?
$1906  JMP $2473                          ; -> STA $D01A (kill raster IRQ), JMP $20A3
$1909  CMP #$91 / BCS $1906               ; above it?
$190D  ...the actual work...
```

The mask lives at `$5700`-`$88FF`, so `$50` and `$91` bracket it with room to spare. **If the
coastline walker runs off the buffer, the World Maker disables interrupts and starts the entire
generation over.** That is worth knowing on its own — a run that looks hung may be regenerating,
not stuck — and it is probably part of why generation takes about 18 minutes.

Measured coverage shows `$1900` executing 1,156 times in a single phase, so the guard is passed
constantly and the restart is rare. Do not read the `JMP` as the routine's purpose; an earlier
version of this note did exactly that, on the strength of a breadth-first path rather than the
four instructions above it.

One such edge is enough to make essentially every routine "reachable" from every other, so any
question of the form "what does this phase depend on" is unanswerable from the call graph.

### There are two "give up and start over" paths

`$2473` is reached from the bounds guard above **and from the raster interrupt itself**. The IRQ
handler ends:

```text
$2463  LDA $AF / BNE $246D          ; skip the check once the second wave starts
$2467  LDA $BE / CMP #$08 / BEQ $2473
$246D  PLA / TAX / PLA / TAY / PLA / RTI     ; normal exit
$2473  LDA #$00 / STA $D01A / JMP $20A3      ; kill the raster IRQ, regenerate
```

`$23D3` zeroes the frame counter `$BD`/`$BE` before each fill and the IRQ increments it at `$240D`,
so `$BE` reaching 8 means roughly 2,048 frames — about 34 seconds of emulated time — have passed
inside a single landmass fill. That is a **watchdog**: the coastline walker can evidently wander
long enough to be worth abandoning, and the response is to throw the whole world away and start
again.

So generation has two failure paths, one spatial (`$1900`, the walker leaves the buffer) and one
temporal (this one), and both restart everything. That is very likely a large part of why
generation takes about 18 minutes, and it matters for the port: a port that assumes the phase runs
exactly once is not reproducing the original's behavior, only its usual behavior.

**The frame counter feeds nothing else.** Scanning the binary for zero-page references to `$BD` and
`$BE` finds only `STA` at `$23D5`/`$23D7`, `INC` at `$240D`/`$2411`, and this `LDA` at `$2467`. A
scan like that does throw false positives — it reported a `DEC $BD` at `$111B` that is really the
operand of `CMP $C6` followed by the opcode of `LDA $11DD,X`, an instruction-boundary straddle — so
check each hit against the disassembly before believing it.

Measure coverage instead — `tools/wm_coverage.py` puts a non-halting checkpoint
(`stop=False`, which still counts hits) on every `JSR` target, runs the phase between `$212A` and
`$280A`, and reports which routines actually ran. Routine granularity is enough to scope a port
and keeps it to a couple of hundred probes instead of per-instruction tracing.

**Result: 64 of 207 routines execute.** That is the real size of the land-mass port, against 207
by call graph. The phase also completes in about 7 seconds under warp with all 207 probes armed,
so this is a fast experiment to re-run per configuration.

Caveat on that number: it was measured between `$212A` and `$280A`, so it covers the command-table
stage only and **excludes the second wave** at `$280A`-`$2894`. `wm_coverage.py` now runs to
`PHASE_DONE`; re-run it for the figure that covers the whole phase.

The hot ones are the primitives already identified — `$142F` (144,659 calls) and `$1B4E`
(103,249) are the mask address and bit test, then the multiply and divide, then `$141C`. The
walker's own body (`$15AD`, `$16BB`, `$16BF`, `$1728`, `$1731`, `$178A`, `$19CC`, `$1A00`,
`$1B3B`) is the substantial unread block.

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

### Done: the land-mass phase is reproducible (`tools/wm_deterministic.py`)

The plan above works, with one change — patch the **seeding site** rather than writing `$CD`/`$CF`
after startup, so the seed does not depend on catching the right moment:

    $20CB  LDA $D41B / STA $CD / LDA $D41B / STA $CF   ->  LDA #hi / STA $CD / LDA #lo / STA $CF
    $2406  LDA $D41B / ADC $CD / STA $CD               ->  NOPs
    $2146  JSR $0AE2 .. JSR $0A6E                      ->  LDA #config

Those are the only hardware reads that matter. `game3` touches hardware in exactly seven places:
the SID noise rig at `$2090`/`$2093`/`$2098`, the two seed reads, the IRQ stir, and `$0A49`
(`LDA $D012`) — which is a raster sync that spins until scanline `$FE` and always returns the
same value, so it needs no patch.

Verified: the same `(seed, config)` reproduces all 12,800 bytes of the mask exactly, and both a
different seed and a different configuration change it.

**One unexplained divergence, so the harness now verifies rather than assumes.** An early capture
of seed `$0001` configuration 0 produced a mask differing from every run since by a **single
isolated cell** — 29,790 cells and 5 masses against 29,789 and 4. Every other case reproduced
exactly, and that case has since reproduced identically seven consecutive times. Three candidate
causes were tested and all three ruled out:

- **Disk state.** The World Maker writes to the attached image, so it could accumulate. Running the
  same case against three different disks gives identical masks; the disk is not an input.
- **Leftover RAM.** Earlier harnesses poke drivers at `$C000`. Writing a marker there and hard
  resetting shows VICE reinitializes RAM, so nothing carries over.
- **The frame counter.** It only reaches the watchdog at `$2467`, which can restart the whole
  generation but cannot alter one cell.

Since the cause is unknown, `capture_fixtures` runs every case **twice and compares**, failing
loudly on any mismatch. Determinism is the assumption the entire oracle rests on; it has been wrong
once, and a silently wrong fixture would make the port's tests green against the wrong target.

**The IRQ handler is not in `local/game3.disasm.lst`.** It is reached through the IRQ vector,
never by `JSR` or `JMP`, so recursive descent never walks it — which is why `grep`-ing the listing
for `$D41B` finds only two of the three reads. The listing has gaps wherever control arrives by
vector. Verify bytes against `game3.bin` itself, not the listing.

**Fixtures are digests, not masks.** A land mask is 12,800 bytes of map produced by Ozark
Softscape's generator, and this project does not ship map data; the existing fixtures are numeric
behavior of general-purpose routines, which is a different kind of thing. `landmass_reference.json`
carries a SHA-256 per case plus land-cell count and blob areas — a bit-exact test, diagnosable on
failure, and no game content. Full masks go to `local/wm_masks/`, which is gitignored.

### Done: RNG ported and verified

`SevenCitiesCore/Sources/SevenCitiesCore/WorldMakerRNG.swift` is a literal transcription.
`tools/rng_reference.py` executes the original routine in VICE across 5 seeds x 64 values and
writes a fixture; the Swift tests assert an exact match on both output and internal state.
Confirmed non-vacuous by mutation: changing the four `ROL A` rotates to three produces 949
recorded failures.

### Done: the bounded draws ported and verified

`$22B4` (8-bit) and `$247B` (16-bit) are transcribed into `WorldMakerRNG` as `nextByte(from:below:)`
and `nextWord(from:below:)`, with `tools/randrange_reference.py` capturing reference output from
the original across 4 seeds — 40 byte cases replayed as sequences, 24 word cases from fresh seeds.

Three things that had to be right:

- **They are rejection samplers, and the waste matters.** Each rejected candidate still advances
  the LFSR, so a port that reduced one draw by modulo would produce plausible values and
  desynchronize every later draw. The byte fixture is deliberately a *sequence* from one seeding
  rather than independent cases, so it tests that the same candidates get thrown away.
- **`$247B` consumes two advances per candidate.** The first supplies the low byte; the second is
  drawn only for its sign, and the high byte is 1 when that draw is below `$80`, else 0
  (`LDA $CF / BMI / INX` at `$24E1`). Results are therefore capped at 511 — exactly enough for 400
  rows, and a strong hint the 9-bit shape is deliberate.
- **The bounds are two parameters, not a `Range`.** Swift's `Range` traps at construction when
  inverted, so it cannot represent `lo > hi` — which `$22BA` explicitly handles by returning `lo`.
  Modelling these bounds as a `Range` would impose an invariant the 6502 does not have and convert
  a reachable path into a crash. Two of the three tests failed this way before the signature
  changed; the type system was reporting a real mismatch, not being awkward.

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

### A 6502 interpreter, for stepping generation in-process (`tools/sim6502.py`)

Built because the coastline walker cannot be debugged any other way. It is a backtracking search
with three self-modifications and a stack-discarding non-local exit; transcribing it and comparing
the finished 12,800-byte mask yields exactly one bit of feedback — "the walk went somewhere else" —
with no way to localize a fault. Running the original in-process makes every intermediate state
observable, so a port can be diffed against it step by step. Every later phase gets the same.

Scope is official NMOS opcodes, binary arithmetic, no interrupts, no I/O beyond a read hook.
Unknown opcodes **raise** rather than being skipped: a silently ignored instruction produces
plausible, wrong output, which is the exact failure this tool exists to prevent. Decimal mode
raises too.

**It is validated against the real chip, not against itself.** `--check` replays the LFSR at
`$0AE2` and the multiply and divide at `$0A51`/`$0A6E` against fixtures captured from the 6502
running under VICE — 5 sequences and 3,840 arithmetic cases. Those fixtures were produced
independently, so agreement is evidence about the interpreter rather than about the routines.

Two things it cannot do, both learned by running into them:

- **It cannot boot the World Maker.** Initialization talks to the 1541 over the serial bus:
  `$13BC` reads `$DD00` twice to debounce and shifts the DATA line into carry, and `$1287`/`$128C`
  spin on the result. With no drive that never completes — measured at 855,591 reads of `$DD00`
  and no progress. `tools/wm_snapshot.py` therefore lets the emulator do the boot and dumps RAM at
  `$212A`; the interpreter starts from there, which also guarantees the initial state matches the
  one the reference masks came from. Snapshots are 64 KB of the game's own code, so they are game
  data and live in `local/`.
- **`$D012` must read `$FE`**, or the raster sync at `$0A49` spins forever. Nothing else advances
  it without interrupts.

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
- **To wait for a checkpoint, poll its `hit_count`.** Neither obvious alternative works, and
  both fail *quietly*, which is what makes this expensive:
  - `vice_ping` reports `execution: paused` for reasons unrelated to checkpoints, so a ping loop
    announces a halt that never happened and RAM gets read mid-phase. Runs were misread this way
    as stopping at `$22DB`, `$2385` and `$236C` — all inside the placement loop, none of them a
    checkpoint. `wm_trace.py` still waits this way and its snapshots deserve re-checking.
  - The PC is readable while the CPU is running and simply never equals the target when sampled,
    so waiting for a match spins until the timeout.

  `hit_count` is unambiguous: zero until the checkpoint fires, nonzero after.
- **Restore `$01` to `$37` before resetting.** `game3` runs with ROM banked out (`$01 = $35`). If a
  run ends with the CPU halted inside it, the next reset has no ROM to reset *into* — `$FFFC` reads
  RAM, and VICE answers "Machine power cycled" while the PC never moves. Symptoms include a PC that
  reads back as `0x10002`, which is not even a valid 16-bit address. This wedged the emulator twice
  in one session, once badly enough to need a manual restart. `boot()` now pauses, writes `$37` to
  `$01` and resets before doing anything else, every time rather than only in recovery.
- **Use execution checkpoints, not store checkpoints.** Every `exec=True` experiment in this
  project has worked first time. The one `store=True` watchpoint — on `$21`, to find what writes it
  — recorded a single write, stalled for four minutes, and left the emulator **unrecoverable**.
  It halted inside `game3`, which runs with ROM banked out (`$01 = $35`). RAM was then
  reinitialized under a CPU parked at `$206B` with no ROM visible, so the reset vector at `$FFFC`
  read RAM as well and there was nothing to reset into. `vice_machine_reset` cheerfully answered
  "Machine power cycled" while the PC never moved; soft reset, hard reset, pausing first and
  restoring `$01` by hand all did nothing. VICE had to be restarted by hand.

  To find what writes a location, bisect with exec checkpoints at successive points and read the
  value at each. It takes more round trips and it cannot wedge the machine.

  **Arm every point at once; do not clear and re-arm between them.** Deleting the checkpoint the
  CPU is currently halted on *resumes* execution, so a clear-then-arm loop lets the machine run
  free until the next checkpoint exists — and it has usually gone past. A first attempt at this
  bisect sampled six points that looked like one iteration and were not: `$54` read 0, then 2, then
  5, and 5 only occurs in the second wave, so the last sample was thousands of instructions past
  the first. Sampling a second, unrelated variable is what exposed it; with only the value under
  investigation the drift would have looked real.

  If a store checkpoint is genuinely unavoidable, restore `$01` to `$37` **before** the halt, not
  after — once the CPU is parked with ROM banked out there is no way back.
- **Prefer patching code over setting registers at a checkpoint.** Forcing a value by stopping at
  an instruction and writing a register assumes the stop happened where you think it did, and
  when it did not the run still completes and returns plausible numbers. Patching the
  instructions that compute the value makes the result independent of timing, and a read-back of
  the patched bytes verifies it took.

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


## Correction, twice over: the `game` file is a red herring

This section has been wrong in both directions, so here is the settled version.

**First claim: "the code is not packed or encrypted."** From a crude JSR/RTS
density heuristic. Withdrawn.

**Second claim: "`game.prg` IS packed."** Also wrong, and it stood much longer.
The evidence looked overwhelming:

| Binary  |   Size | JSR | BNE | `AND #$0F` |
| :------ | -----: | --: | --: | ---------: |
| `game3` | 18,432 | 938 | 433 |          5 |
| `game`  | 36,096 |  66 |  34 |      **0** |

Zero `AND #$0F` in 36 KB really is impossible for 6502, so `game` really is not
code. The error was the inference drawn from that: **not code** does not imply
**packed code**. It can simply not be the program.

**What is actually true:** the loader never opens `game`, never reads the
directory, and never follows a sector chain. It issues raw `U1:` block reads
from track 1 sector 0 and stores every byte verbatim. The program lives in the
**248 sectors that are BAM-allocated but belong to no file, on tracks 1-10 and
34-35** — noted in the file table above long before anyone realized that was
where the game was. `game` at track 17 sector 7 is something else; the loader
never touches it.

So there was never a packed payload, never a depacker, and the "7.04 bits/byte
entropy" measured on `game.bin` was measuring a file the game does not use.
See "Resolved: there is no depacker" below for the loader's actual data path
and for how to extract a stage statically.

`tools/decrypt_game.py` reads the program straight off a disk image, so the
emulator is no longer required to get at the code. The tool that used to boot
the game and dump RAM for this has been deleted; `catch_decrypt.py` does the
same thing and stops at the right instant.

## Display modes (from the unpacked binary)

| Site    | Write              | Meaning                                |
| :------ | :----------------- | :------------------------------------- |
| `$1501` | `$D011` = `$1C`    | bit 5 set — **hires bitmap mode**      |
| `$14FC` | `$D016` = `$C8`    | bit 4 clear — hires, not multicolor    |
| `$1506` | `$D018` = `$34`    | video matrix `$0C00`, bitmap at bank+0 |
| `$2C6E` | `$D018` = `$38`    | bitmap at bank+`$2000`                 |
| `$2C81` | `$D011` = `$17`    | bit 5 clear — **text mode**, 24 rows   |

So the game switches between a **hires bitmap** map/exploration view and a
text-mode view for menus and the court. Sprites (`$D000`/`$D001`/`$D015`) are
used for the moving party, not for terrain.

### This answers the cell-versus-sprite question

Terrain is drawn as **8x8 hires bitmap blocks**, one per map cell — not sprites
and not charset tiles. And the scale now reconciles:

- exploration view: 320/8 = 40 cells across = 120 miles, so **~3 miles per cell**
- map view at 960 miles per screen is 8x that = 320 cells, which is the whole
  256-wide map — the map view shows the entire world width, exactly as the
  manual implies

The world is therefore about 768 x 1,200 miles internally. Not geographically
accurate against the real Americas (~9,000 miles north to south), but
internally consistent, and the manual's figures are the game's own scale rather
than a claim about reality.

For the port this is good news: the map is a straight 256x400 tile grid at
~3 miles per tile, and a zoomable renderer needs one tile image per terrain
nibble, not procedural detail generation.

## The game's own terrain vocabulary (`$1566`)

A table of 8-byte names in the game's custom font encoding (character index =
ASCII - `$20`), copied to a status line at `$8EE4` by the routine at `$33FD`:

```text
0 DEEP    1 MEDIUM   2 SHALLOW   3 SHIP
4 RIVER   5 PLAIN    6 FOREST    7 MOUNTAIN
8 SWAMP   9 VILLAGE  A CACHE     B FORT      C MISSION
```

So the game distinguishes three water depths, and `CACHE`, `FORT` and `MISSION`
are things the player builds during play rather than generated terrain.

**This enum is not the raw map nibble.** Indexed directly by nibble it would
make `B` (21% of the map) a FORT, which is absurd. Some translation happens
between reading a cell and naming it; the translation table has not been found
yet and may be computed rather than stored.

### Independent confirmation of the nibble decode (`$468F`)

A 16-entry table indexed by **map nibble**:

```text
index:  0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
value:  0  0  0  0  3  3  3  3  3  3  3  2  1  2  3  6
```

The groupings match the empirical decode exactly — water `0`-`3` together, all
seven river values `4`-`A` collapsing to a single class, then `B`, `C`, `D`,
`E`, `F` separate. This is the game agreeing with the map analysis, arrived at
from completely different evidence. Note `E` groups with rivers and swamp is in
the vocabulary, which supports `E` = SWAMP.

## Open: where are the terrain tile bitmaps?

Not yet found, and **not** in `game_unpacked.bin` — an entropy profile of the
unpacked binary shows almost no graphics-like regions, so it is nearly all code
and tables.

Most likely they live in the 62 KB of raw sector data on disk 1 tracks 1-10,
which is where the font was found and which the fastloader reads directly.
That region is still only partly explored.

The display is hires bitmap at 8x8 pixels per map cell, so each terrain type
needs 8 bytes of pattern plus a color nibble pair in the video matrix.


## Map of disk 1's raw region (tracks 1-10, sectors 0-19)

51,200 bytes. Content lives only in roughly the first 11 KB; everything past ~11,300 is a
repeating filler pattern.

| Offset        | Contents                                            |
| :------------ | :-------------------------------------------------- |
| 0 - ~1,800    | vertical stripe patterns                            |
| ~1,800 - 4,700| dense graphics                                      |
| **4,714**     | **font**, 96 glyphs, ends 5,482                     |
| 5,482 - ~11,300 | dense dithered patterns — terrain tile candidates  |
| ~11,300+      | filler                                              |

## Solved: terrain tiles are multicolor CHARACTERS

The exploration view is **multicolor text mode**, not bitmap. Live VIC state while exploring:
`video_mode` 1 (multicolor text), 24 rows, `$DD00` = `$C1` (VIC bank `$8000`), `$D018` = `$3B`
giving video matrix `$8C00` and **charset `$A800`**.

So terrain is drawn as 8x8 multicolor characters — 4 double-width pixels per row, 2 bits each.
That is why the glyphs look like noise when rendered 1bpp.

Charset layout as dumped from the running game:

| Range     | Contents                                                     |
| :-------- | :----------------------------------------------------------- |
| `$00`-`$3F` | the ASCII-ordered font (matches the disk extraction)        |
| `$40`-`$5F` | coastline / shore shapes, land against water                |
| `$5A`-`$64` | brown rock and mountain forms                               |
| `$65`-`$77` | dithered brown/green/blue — forest and swamp textures       |
| `$80`-`$AF` | green tiles with blue river segments in varying connections |
| `$B0`-`$FF` | unused filler                                               |

The river glyph range mirrors the six river connection masks in the map data.

**The terrain charset is not on disk anywhere** — not in the raw region, `game2`, `game3`,
`game4`, or tracks 34-35. Like the game code, it is unpacked at runtime, so it has to be
extracted from RAM. `local/terrain_charset.bin` is a 2 KB dump; the bitmap-mode path found
earlier at `$1501` is presumably the separate zoomed-out map view.

### Old note (superseded) The region after the font is full of dithered 8-byte patterns that are
plausible hires terrain texture, but forest cannot be told from mountain by eye, and there are
far more patterns (~6 KB) than the 16 terrain types need at 8 bytes each. Likely several
variants per terrain type, mixed with other graphics.

The reliable way to settle it is to capture the game's own rendering and match tiles against
it. That needs the game to accept a map disk.

**`d64/HISTMAP.D64` works.** A copy of `7CITIES2.D64` with its BAM and directory rewritten to
look like World Maker output (name `map`, id `ea`, 0 entries, BAM showing 2/683) is **accepted
by the game**. The map-disk validation really is just the directory. This is the key that
unlocks everything in `game.prg`.

With it attached, the OBSERVER (DEMO) mode plays itself — and the demo only runs on the
historical map, which is exactly what this disk is. No joystick needed to reach the
exploration view.

## Correction: the exploration viewport is a software bitmap

An earlier note read chars `$40`-`$AF` as a reusable terrain tileset. That was
wrong. Dumping the screen matrix during exploration shows the 12x12 viewport at
screen cols 14-25, rows 4-15 using **unique sequential character codes**,
column-major:

```text
r4:  70 7c 88 94 a0 ac b8 c4 d0 dc e8 f4
r5:  71 7d 89 95 a1 ad b9 c5 d1 dd e9 f5
r6:  72 7e 8a 96 a2 ae ba c6 d2 de ea f6
```

Every cell has its own character. The game **redefines the character bitmaps
each frame** to draw terrain — a software bitmap built out of chars, 12x12
cells of 8x8 multicolor, so 48x96 logical pixels. Chars `$40`-`$6F` are static
UI decoration and the viewport frame; `$70`-`$FF` are the dynamic surface.

So there is no fixed 16-entry tile atlas to extract. What a previous dump
captured was one frame's rendered content.

Live colors during exploration: `$D021`=`$7` yellow (land), `$D022`=`$E` light
blue (water), `$D023`=`$5` green (vegetation). Multicolor bit pairs select
bg0/bg1/bg2/fg.

**Color RAM in multicolor char mode:** bit 3 is the *multicolor flag*, not part
of the color. Every viewport cell here holds `$8`, which means "multicolor on,
foreground = 0" — **black**. Masking with `& $0F` instead of `& $07` renders
ship, tree trunks and mountains orange when they should be black.

**Consequence for the port.** The renderer cannot be a straight tilemap of 16
terrain images. The original composes a scene from the surrounding map cells,
placing trees, mangroves, hills and coastline shapes procedurally within the
viewport. Reproducing it faithfully means understanding that composition step,
not just extracting art. A remaster could instead draw its own tiles from the
decoded 256x400 grid — which is the simpler path and already fully unblocked.

`tools/boot_demo.py` reaches this state automatically and captures the screen
matrix, color RAM and charset.

## The map viewer

`SevenCitiesCore/Sources/MapViewer` — a macOS SpriteKit viewer for a decoded
world. Run it with:

```bash
python3 tools/extract_map.py d64/7CITIES2.D64 local/historical.map
python3 tools/extract_map.py local/generated_world.d64 local/generated.map
python3 tools/boot_demo.py local && python3 tools/extract_tiles.py
cd SevenCitiesCore && swift run MapViewer ../local
```

Two menus, as asked: **World** picks the classic Americas map or a generated
one; **Tiles** picks original or custom art. Defaults are the classic map with
original tiles.

Controls: arrows, numpad, or the `YUI`/`HK`/`NM,` cluster to walk; drag or
scroll to pan; `=`/`-` to zoom; `0` to fit the whole world; `f` to re-centre on
the explorer.

The whole 256x400 grid goes into one `SKTileMapNode`, which culls for us, so
zooming out to the entire world stays cheap.

### "Original tiles" is necessarily approximate

The original has **no tile atlas**. It composes its viewport procedurally into
redefined characters, drawing mountains and some trees as shapes that span
several cells, so no single 8x8 character holds a whole one. What
`tools/extract_tiles.py` lifts is the most representative fragment of each.

Eight tiles are the original's own pixels (water, shallows, plain, forest,
swamp, mountain, ship). Rivers and villages did not appear in the captured
frame and are reconstructed in the original's own 4-color 8x8 grid; the viewer
labels the split in its title bar.

So "Original" mode is faithful to the original's palette and pixel style, not
to a tileset it actually had.

**`local/original_tiles.json` is never committed** — unlike the RNG test
vectors, those are the original's pixels.

### Opening the project in Xcode

There is no `.xcodeproj` — this is a Swift Package. Open it with:

```bash
open SevenCitiesCore/Package.swift
```

or in Xcode use File > Open and select `Package.swift`. Xcode builds, runs and
debugs SwiftPM packages natively; a generated project would only drift.

To run the viewer from Xcode, edit the `MapViewer` scheme and add the asset
directory as an argument (the absolute path to `local`).

### Bug worth remembering: lockFocus and SKTexture

The viewer first came up as bare background with only the explorer visible. The
cause was building `SKTexture(image:)` from an `NSImage` that was still inside
`lockFocus()` / `unlockFocus()` — the texture comes out empty, silently.

Draw into a `CGContext`, call `makeImage()`, and use `SKTexture(cgImage:)`.

`MapViewer <assets> --dump <out.png> [historical|generated] [original|custom]`
renders the tileset and a slice of the world through the same texture path
without opening a window, so this class of failure is visible in a file rather
than needing a screen.


## The loader is a bytecode VM (copy protection)

Going after the depacker statically found something better than a depacker: the
`$C000` loader is a **virtual machine**, and the `04 8B 07 6D CE`-style data
filling `$C047`-`$C25F` is its bytecode program.

### Dispatcher — `$C482`

```text
$C487  JSR $C4E8       ; steals the return address: the bytecode follows the JSR
$C492  LDA ($26),Y     ; fetch opcode
$C499  TAX
$C49A  LDA $C4AD,X     ; opcode table
$C49D  CLC / ADC #$C1  ; handler = $C400 + (entry + $C1), carry into the high byte
$C4A0  STA $C4AB       ; self-modifies its own JMP operand
```

Every handler ends `JMP $C492` to fetch the next opcode — a classic threaded
interpreter.

### Obfuscation constants

| Where   | Transform  | Applies to                        |
| :------ | :--------- | :-------------------------------- |
| `$C4D3` | `EOR #$41` | low byte of a pointer operand     |
| `$C4E3` | `EOR #$CE` | high byte of a pointer operand    |
| `$C52E` | `EOR #$8B` | immediate operands                |
| `$C58E` | `EOR #$8B` | immediate operands (subtract)     |
| `$C5C8` | `EOR #$7F` | derives a key from the page byte  |

### Opcode map (20 handlers)

```text
$00 $C4C1   $01 $C4FD   $02 $C500   $03 $C51E   $04 $C528
$05 $C536   $06 $C553   $07 $C576   $08 $C587   $09 $C518
$0A $C56B   $0B $C542   $0C $C582   $0D $C59C   $0E $C59F
$0F $C5A2   $10 $C5A5   $11 $C5A8   $12 $C5AB   $13 $C5AE
```

Identified so far: `$04` load immediate (`EOR #$8B`), `$05` load indirect,
`$08` subtract immediate, `$0C` `ASL $28`, and a decrypt primitive at `$C5B0`
that XORs two bytes in place with a key equal to the pointer's high byte
`EOR #$7F`.

### What the file itself is

- `game.prg` has entropy **7.04 bits/byte across all 256 values**, so it is
  compressed, not merely masked.
- The page-keyed XOR above does **not** decode it — tried with masks `$7F`,
  `$00` and `$FF`, none produced valid code or any known plaintext. That
  primitive decrypts whatever region the VM points at, not the game file.
- A comparison made earlier between `game.prg` and RAM at `$0800-$94FF` was
  meaningless: compressed input cannot expand in place at the same addresses,
  so the unpacked code must live elsewhere. That comparison should be redone
  once the destination is known.

### The bytecode reads cleanly

`tools/vmdis.py` disassembles it. The bytecode begins **six bytes after each
`JSR $C482`** — the dispatcher points at the return address and starts at
`Y = 4`. Empirically that is the only alignment giving long runs of valid
opcodes (27, 21 and 33 from three of the four entry sites).

What the loader's program actually does:

```text
$C033  LDA $02F0 / SUBI #$9D / JNZ $C3CE    ; tamper check on KERNAL vectors
$C03B  LDA $02D4 / SUB $C002 / JNZ $C3CE    ; second tamper check
$C047  LDI #$30 / STA $C2C7 / STA $C2C8     ; seed the "U1:2,0,01,00" digits
$C062  LDI #$00 / STA $2C, LDI #$21 / STA $2D
$C06C  loop pages $21..$A0 calling SYS $C07D
$C095  loop pages $CA..$D0 calling SYS $C07D
$C0AB  SETNAM / SETLFS / OPEN, then LISTEN / SECOND / UNLSTN
$C100  prints "ERROR" via CHROUT
```

`SYS $C07D` is a **RAM test**, not a decryptor — it writes a byte and reads it
back. `$C465` is a rolling checksum over `($2C)`; `$C44D` a counter.

So the loader's bytecode is a tamper check, a memory test and the disk I/O
driver. It also seeds the drive command string decoded in the very first
session: the whole loader is one program.

### The loader does not transform anything — but `game` is still unexplained

**Scope note, written after briefly getting this wrong in both directions.**
What follows about the `$C000` loader is verified. The conclusion "therefore
nothing is packed" that was drawn from it is **not**, and was withdrawn within
the same session. See "What `game` is, and is not" below for the honest state.

The `$C000` loader is only the **first-stage** loader. It ignores the directory
completely: it issues raw `U1:` block reads and walks **track 1 sector 0
onward, sectors 0-19 per track**, storing whole sectors page-aligned. It loads
stage 1 and hands off. It never touches the file named `game`, and it has no
decompressor in it anywhere. Everything after stage 1 is loaded by some other
mechanism that has not been identified yet.

#### How the loader actually moves data

The whole path is now readable end to end. `tools/vmtrace.py` follows every
branch of the bytecode instead of one straight-line run at a time:

```text
$C033  tamper checks on $02F0 / $02D4        -> $C3CE on failure
$C062  RAM test, pages $21..$A0 and $CA..$D0
$C0AB  SETNAM "I0:" / SETLFS 15,8,15 / OPEN  ; command channel
       SETNAM "#"   / SETLFS  2,8, 2 / OPEN  ; drive buffer
$C0ED  LISTEN 8 / SECOND $6F / send "U1:2,0,tt,ss" / UNLSN
$C176  LISTEN 8 / SECOND $6F / send "B-P:2,0"     / UNLSN
$C189  TALK 8 / TKSA $62, then the transfer loop
$C200  INC $2D; if $2D != $C004 loop back to $C0ED
$C21B  SYS $C25A  -> checksum; JNZ $C100 prints "ERROR"
$C230  JMPIND $C2B5 = JMP $1038                   ; hand off to the loaded stage
```

The transfer loop is the point. It applies **no transform whatsoever**:

```text
$C19B  JSR $FFA5        ; ACPTR — one byte off the serial bus
$C19E  STA ($2C),Y      ; stored verbatim, 256 bytes per sector, page aligned
$C1AA  INY / BNE $C19B
```

The `LDA $2D / EOR #$00 / STA $2D` pair bracketing that loop looks like a
self-modifying page scrambler, and that is a good guess — but nothing in the
loader ever writes `$C196` or `$C1C1` (checked for both native `STA abs` and
the bytecode `STA` encoding). The operands stay `$00`, so the pair is
vestigial.

`$C25A` is likewise only verification — a rolling 8-bit sum over pages
`$C003..$C004`, minus `$C005`, and `$C21E` branches to the "ERROR" printer if
it is non-zero. It is not a depacker.

#### Extracting a stage statically

`$C003`/`$C004`/`$C005` are **per-load parameters** — start page, end page,
checksum — read by the loader on each pass. The values sitting in a RAM dump
therefore describe whichever load ran last, not the first one, which is why the
first stage does not satisfy the `$04` checksum found in a dumped loader.

**Who writes them is not known.** A byte scan of stage 1 turns up `20 03 C0` at
`$19D8` and it is tempting to read that as `JSR $C003`, but recursive-descent
disassembly from every in-range `JSR` target never reaches `$19D8` — it is
unreachable, so those three bytes are data and the "stage 1 re-enters the
loader here" reading is a false positive from pattern matching. Nothing in
stage 1, `game2`, `game3` or `game4` writes `$C003`-`$C005` or the drive's
track/sector digits by a direct `STA`, and none of them call any KERNAL I/O
vector either. So how anything after stage 1 gets loaded is still open.

The same care applies to `$1038`: disassembled properly it is the middle of a
routine starting at `$1033` (`CMP #$00 / BEQ / CLC / ADC $14 / CMP $14 / BNE`),
which confirms it is not stage 1's entry point but a per-load parameter.

The first stage is **track 1 sector 0, sectors 0-19 per track, 44 sectors,
page-aligned to `$0800-$33FF`**. Extracted that way it is immediately real
6502 — a delay loop at `$1040`, a `$D012` raster wait at `$104B`, and an LFSR
at `$106F` with the same `ROL x4 / AND #$02 / EOR / ROL / ROL` shape as the
World Maker RNG. Pages `$08-$0F` are `4C 0C` filler; code starts around
`$1000`, which is why the entry is `$1038`.

The `$0800` load address is not assumed, it is measured two independent ways:

- **JSR coherence.** Of the 47 `JSR` targets that land inside the stage, 68%
  point at a byte that is a common opcode. The neighboring load addresses
  score 19%, 26%, 30% and 47%.
- **Self-modifying code.** `$1058 STA $1066` patches the operand of
  `$1065 CMP #$65`, and `$1077 STA $1086` patches the operand of
  `$1085 EOR #$85`. Both land exactly where they must, which only happens at
  the right base.

Note that the entry `$1038` disassembles as `ADC $14 / CMP $14 / BNE / RTS`,
which is not a plausible handoff target — so `$C2B5`'s operand is evidently a
**per-load parameter too**, like `$C003`/`$C004`/`$C005`, and `$1038` is the
entry of whichever stage loaded last before the dump. Stage 1's own entry is
still unknown.

The decisive confirmation is the text at `$1DE0-$1EF0`, stored as **screen
codes offset by `$20`** (subtract `$20`, then `$01-$1A` are `A-Z`):

```text
OZARK SOFTSCAPE COPYRIGHT (C)
PRESS  F3  TO CREATE ANOTHER WORLD
PRESS  F7  TO PLAY THE GAME
JIM RUSHING   ALAN WATSON        ROY GLOVER
LOADING WORLD MAKER / GAME PROGRAM
```

That is the title screen, pulled off the disk image with no emulator involved.

Each load leaves the track/sector digits where it stopped, so a following load
*can* continue the stream — but it is not one long sequential read, and the
first stage is not immediately followed by the second. Surveying the tracks in
loader order shows what disk 1 actually holds:

| Tracks  | Contents                                                        |
| :------ | :-------------------------------------------------------------- |
| 1-3     | **Stage 1** — title screen, credits, protection; entry `$1038`   |
| 4-10    | Map storage, blank: `$01` padding throughout, a little `$4B`     |
| 11-17   | Code — highest `JSR` density on the disk is tracks 12-13         |
| 18-22   | Mixed / sparse                                                   |
| 23-25   | Code                                                             |
| 26-35   | `$01` padding                                                    |

Tracks 4-10 being solid `$01` is a nice cross-check: `$01` is exactly the
padding value the map decoder already expects (`MapDecoder.padding`), so that
region is the reserved world slot a generated map gets written into. It also
explains the 248 BAM-allocated sectors that belong to no file.

The remaining stages, including the one holding the `$0AE2` RNG, should be
recovered by extracting the code tracks with `tools/extract_stage.py --skip`
and disassembling. Which `--skip` corresponds to which load is not yet pinned
down; the honest way to settle it is to read the callers of `JSR $C003` in
stage 1 and see what page range and checksum each one sets up.

~~The drive code uploaded by `$C29A`/`$C2A1`~~ — **not drive code.** Both just
send bytes from the command string at `$C2B9` (`"I0:" "#" "U1:2,0,01,00"
"B-P:2,0"`) via `CIOUT` (`$FFA8`): `$C29A` sends `Y = $10..$17`, `$C2A1` sends
`Y = $04..$10`. No drive code is uploaded anywhere in the loader.

`DECRYPT2` (opcode `$0F`) is used at `$C445`-`$C448`, and a per-page XOR was
ruled out exhaustively against four load addresses. Both of those remain true
and are now simply unremarkable: `DECRYPT2` unmasks small regions inside the
loader's own bytecode, and there was never a packed payload for a page XOR to
decode.

### Solved: `game` is enciphered with a fixed byte substitution

`game` is the main program — 36,096 bytes loading at `$0800`, so `$0800-$94FF`.
On disk it is not 6502 (66 `JSR`, zero `AND #$0F`). It is **enciphered**, and
the cipher is now recovered exactly.

#### What the live game does

`tools/watch_unpack.py` samples `$0800-$94FF` through the load after F7:

```text
    t   match% vs game.bin    JSR    opcode%
    0        34.57             47       5.9     loading
    3        68.23             64       8.1     loading
    6        99.60             66      11.0     loaded VERBATIM
    9         0.00           1114      27.3     transformed in place
```

So `game` is loaded byte for byte and then transformed **in place**, 36,096
bytes in and 36,096 out. **Equal size rules out compression** — this is a
cipher, and there is no depacker in the ordinary sense.

#### Recovering the cipher

`tools/catch_decrypt.py` polls a small window until it stops matching the file,
**pauses the machine on the spot**, and dumps `$0800-$94FF`. Pausing matters:
a dump taken even seconds later is contaminated, because the running game
immediately zeroes buffers and writes variables.

That gives a complete known-plaintext pair, and the cipher is the simplest
thing consistent with it: **a fixed, position-independent byte substitution**.
The table reproduces the plaintext from the ciphertext with **zero errors over
`$0800-$8BFF`** — 33,792 bytes, all 256 input values, 256 distinct outputs.

Above `$8C00` the comparison is meaningless: `$8C00` is the video matrix and
`$8D00-$94FF` is work buffers, and the game overwrites them within the ~0.15s
before the pause. That is the whole of the 4.26% apparent mismatch — 1,539
bytes, essentially all of them in those pages.

The substitution is a bijection but is **not** affine over GF(2) or mod 256,
and does not factor into any short composition of `EOR`/`ADC`/`SBC`, nor into
subtract-then-bit-permute. It is kept as a table in `tools/decrypt_game.py`.
The table is regular enough to suggest a closed form exists — within a row,
`out = r ^ ((r & 4) << 1)` with `r = ($A - lo) & $F` — but the full-byte rule
has not been found, and the generating routine is not in RAM either (the table
does not appear anywhere in `$9500-$FFFF`, so the decryptor computes it).

Note the loader's own `DECRYPT2` VM primitive at `$C5B1` is a *different*
cipher and decrypts the loader's bytecode, not the game:

```text
$C5B3  LDA ($2C,X) / EOR $28 / STA ($2C,X)   ; two bytes per call
$C5C7  LDA $2D / EOR #$7F / STA $28          ; key = page ^ $7F
```

That is the per-page XOR ruled out for `game` long ago, and correctly so.

#### Verification

Decrypting `game` with the table yields `JSR=1117`, `RTS=381`, `LDA #=1018`,
`AND #$0F=290` — a normal 6502 profile — and readable game text, e.g. at
`$153E`:

```text
CAUTIOUS  MODERATE  RECKLESS
```

**The main program can now be decrypted with no emulator.** This unblocks the
game rules and the terrain art, both of which live inside it.

### Inside the decrypted main program

Entry is `$0800 JMP $2D35`. Text is **high-bit PETSCII** (as in `game2`), not
the screen-code-plus-`$20` form stage 1 uses. `AND #$55` masking of charset
bytes and per-glyph rendering confirm the terrain charset really is built at
runtime rather than stored.

Recovered so far, which is what a port needs to match:

| Address   | Content                                                          |
| :-------- | :--------------------------------------------------------------- |
| `$15D6`   | `OPTIONS`, `VIEW MAP`, `DROP STUFF OFF`, `RESUME MOVEMENT`        |
| `$1674`   | `OPTIONS`, `OFFER GIFTS`, `AMAZE THE NATIVES`, `TRADE`, `RESUME MOVEMENT` |
| `$1A13`   | `YOU HAVE DISCOVERED`, `THE MOUTH`/`SOURCE OF A MINOR ...`        |
| `$1A61`   | `DEEP CANYONS`, `BROAD PLAINS`, `RICH PRAIRIES`, `A GREAT LAKE`, `GIANT FORESTS`, `LUSH JUNGLES`, `VAST MOUNTAINS`, `TOWERING TREES` |
| `$1B07`   | month names                                                       |
| `$1B27`   | `THE EXPEDITION IS ON LAND`                                       |
| `$153E`   | `CAUTIOUS`, `MODERATE`, `RECKLESS` (screen-code encoding here)     |

The native-interaction verbs (`OFFER GIFTS`, `AMAZE THE NATIVES`, `TRADE`) and
the discovery vocabulary are exactly the systems `TODO.md` lists as not started,
and they are now readable.

Charset leads, not yet followed to a conclusion:

```text
$14C9  LDA #$C1 / STA $91
$14CD  JSR $0805 ; INC $91 ; CMP #$DB ; BNE  -> 26 glyphs, $C1-$DA
$14D8  LDY #$50
$14DA  LDA $AA00,Y / AND #$55 / STA $AA00,Y   ; multicolor bit masking
$14E2  LDA $AA80,Y / AND #$55 / STA $AA80,Y
```

`$0805` is the character printer (it dispatches on `$80`/`$A0` ranges). The
routines at `$0CF3` and `$0D13` are 1 KB fills of `$A380-$A7FF` and
`$AB80-$AFFF`, so there appear to be two screen buffers rather than the single
`$8C00` matrix recorded earlier for the exploration view.

### The exploration view and its double-buffered charset

Recovered from the decrypted program. **Correction to the earlier note** that
recorded charset `$A800` from a live `$D018` = `$3B`: that was one frame of a
pair. The program never writes `$3B` as an immediate — it writes `$38` and then
flips a bit, because the terrain charset is **double buffered**.

Setup at `$2C41`:

```text
$2C54  LDA #$35 / STA $01        ; bank out BASIC and KERNAL, keep I/O
$2C64  LDA $DD00 / AND #$FC / ORA #$01 / STA $DD00   ; VIC bank $8000-$BFFF
$2C6E  LDA #$38 / STA $D018      ; matrix $8C00, charset $A000
$2C73  STA $02F4                 ; remember it — this is the buffer variable
$2C81  LDA #$17 / STA $D011      ; 24 rows
```

The two charset buffers are `$A000-$A7FF` and `$A800-$AFFF`, and `$02F4` holds
the live `$D018`. The buffer base pages are a two-entry table at **`$0A2A`**:
`$A3`, `$AB` — i.e. the glyph region actually rewritten is `$A380-$A7FF` and
`$AB80-$AFFF`, charset indices `$70-$FF`. That matches the two 1 KB fill
routines at `$0CF3` and `$0D13`, and it matches the river glyphs sitting at
`$80-$AF` in the charset dump.

`$4062` is the animator, and it is self-modifying — it reads a base page from
`$0A2A,Y`, patches it into the operands of its own load and store, then walks
the region:

```text
$4062  LDY $AF / LDX $0A2A,Y
$4067  STX $408E / STX $4093     ; patch the $A380 loop's page
$406D  INX
$406E  STX $407A / STX $407F     ; patch the $A400 loop's page
$4076  LDA $A400,Y / EOR #$55 / STA $A400,Y / INY / BNE   ; 4 pages
$408C  LDA $A380,Y / EOR #$55 / STA $A380,Y / INY / BPL   ; 128 bytes
```

`EOR #$55` flips the low bit of every 2-bit multicolor pixel, swapping
background against `$D022` and `$D023` against color RAM — so this is the
shimmer/animation pass over terrain, not the generator. The generator itself is
still not located.

### The exploration main loop (`$3F08`)

The loop that runs while you are walking around, and the frame in which the
terrain charset is built:

```text
$3F08  STA $AF                  ; buffer index (0 or 1)
$3F11  LDA #$55 / JSR $0CEB     ; fill charset buffer with $55 ...
$3F16  JSR $1076
$3F19  LDA #$55 / JSR $0CEB     ; ... and the other one
$3F1E  JSR $3FA8
$3F21  JSR $38F7                ; <- loop top, the per-frame body
$3F24  LDA $B9 / BNE $3F3F
$3F2C  JSR $400E / JSR $0D70 / JSR $642F
$3F47  JSR $3FE3
$3F4A  JSR $4057                ; the EOR #$55 shimmer pass
$3F4D  LDA $D01F / AND #$02     ; sprite-to-background collision
$3F5C  JSR $6596 / JSR $657F
$3F64  BNE $3F21                ; loop
```

`$0CEB` is "fill the current charset buffer with A": it compares `$02F4`
against `$D018`, syncs via `$0C4B` if they differ, then fills either
`$A380-$A7FF` or `$AB80-$AFFF` depending on `$AF`. Filling with `$55` lays down
a uniform multicolor field before the glyphs are drawn over it.

`$38F7` is a dispatcher rather than the composer:

```text
$38F7  LDA $9E1B / BEQ / JSR $3456
$38FF  LDA $9ECF / BEQ / JSR $3A31
$3907  LDA $D6   / BEQ / JSR $36F0
$390E  JSR $37C2               ; unconditional — the likely renderer
$3937  JMP $33AC
```

Still open: which of `$3FA8`, `$37C2`, `$400E` or `$3FE3` actually composes a
terrain glyph. `$37C2` is the only unconditional call in the per-frame body and
is the place to start.

### Solved: the terrain tiles, statically

The exploration view draws terrain as **redefined characters**, which is why the
charset appears nowhere on either disk. But only the *charset* is assembled at
runtime — the tile **bitmaps are static data inside the main program**, so once
`game` is decrypted they can be read straight out. `tools/extract_tiles_static.py`
does it with no emulator.

#### How the view is built

```text
$3107  12x12 grid of unique character codes into the video matrix at $8CAE,
       code = $70 + row + col * $0C; color RAM filled with $08
       ($08 = multicolor flag + color 0)
$31B4  $B1/$B2 -> the charset glyph region ($AB80 for buffer B); walk 6x6 map
       tiles, advancing $C0 per tile column and $10 per tile row
$58B8  per tile: read the map byte at ($86),Y with Y=$30; low nibble is the base
       terrain, high nibble an overlay; dispatch through the table at $5529
```

The strides are the proof the layout is right: one tile is **2x2 characters**,
so a tile column step is `2 * $0C = 24` codes = `$C0` bytes and a tile row step
is `2` codes = `$10` bytes. 6x6 tiles x 4 glyphs = 144 = the 12x12 grid, and
codes `$70-$FF` are exactly 144 glyphs at `$A380-$A7FF`.

#### The dispatch table at `$5529`

Sixteen 2-byte pointers, indexed by terrain value — and it lines up exactly with
the terrain enum recovered independently from the game's own name table at
`$1566`, which is a good independent check on both.

| Value | Terrain | Pattern |
| :---- | :------ | :------ |
| `$0`, `$2` | deep / shallow water | `$94B0` — a RAM buffer the game animates |
| `$1`  | medium water | `$94D8` — likewise |
| `$3`  | ship | `$5833` |
| `$4`-`$A` | river junction, WE, NW, SW, NS, NE, SE | `$5563` + `$20` each |
| `$B`-`$F` | plain, forest, mountain, swamp, village | `$563B`, `$5653`, `$568B`, `$571B`, `$5753` |

The seven river patterns being exactly `$20` apart is the giveaway that 32 bytes
is one tile. Water is the exception: it points into RAM because it animates, via
the `EOR #$55` pass at `$4057`.

#### Palette

From the setup at `$32C0` and the raster IRQ at `$2250`, which copies shadow
bytes into the VIC registers (`$02C8` -> `$D021`, `$02C5` -> `$D023`, and
`$02F4` -> `$D018`, the charset buffer flip):

| Bits | Register | Value | Meaning |
| :--- | :------- | :---- | :------ |
| `00` | `$D021`  | `$07` | yellow — plains |
| `01` | `$D022`  | `$0E` | light blue — water |
| `10` | `$D023`  | `$05` | green — vegetation |
| `11` | color RAM | `$08 & $07` = 0 | black — rock and outlines |

Rendered, these are unmistakably the original art: a black mountain peak, green
forest clusters, a swamp dither, a village hut, the ship with masts, and every
river connection. This is the classic tileset as **algorithm plus data** rather
than captured pixels, which is what makes it shippable.

### Correction: terrain rendering is position-dependent

Checked against the community reference map (c64-wiki, 4080x6400 = 255x400 tiles
at 16px, i.e. the same 16x16 tiles). Two separate conclusions, and they point
opposite ways.

**The map decode is right.** Per-tile counts against the reference:

| Terrain  | Reference | Ours   |
| :------- | --------: | -----: |
| plain    |    22,120 | 21,897 |
| forest   |     6,249 |  6,266 |
| mountain |     2,516 |  2,540 |
| swamp    |     1,172 |  1,189 |

Nothing is missing from the decode.

**The tile rendering is wrong**, and structurally so. `TerrainTiles` reads one
fixed 32-byte pattern per terrain, but the original composes terrain **from the
tile's map position**. Three classes, from the dispatch at `$5913`:

```text
$5913  CPY #$0D / BEQ $5922      ; mountain  -> variant path
$5917  CPY #$0C / BCC $5941      ; < 12      -> straight copy
$591B  CPY #$0F / BCS $5941      ; >= 15     -> straight copy
$591F  JMP $598A                 ; forest, swamp -> composed from motifs
```

- **Straight copy (`$5941`)** — water, rivers, plain, ship, village. Copies 16
  bytes per character column, two columns, destination advancing by `$58B3`
  between them. Source is 32 sequential bytes: **bytes 0-15 are the left
  character column, 16-31 the right**, which confirms the unpack we already use.
- **Mountain (`$5922`)** — the pointer is advanced before copying:
  `ptr += (x & 3)`, then `ptr += T[x & 1] + T[y & 1]` where `T` at `$58B4` is
  `00 24 48 6C`. So a mountain's appearance depends on where it sits, which is
  how peaks join into ranges. Rendering variant 0 everywhere gives the
  "half mountains and little corners" look.
- **Forest and swamp (`$598A`)** — index a 64-entry table at `$54E9` by
  `((y & 3) * 4 + (x & 3)) * 4`, then scatter motifs at offsets from `$58AB`.
  That is why a wood reads as many individual trees rather than a repeated tile.

Evidence the model is real: the reference's mountain tile matches our data
**exactly** (zero differing pixels) at pointer + 2, and no offset at all
reproduces forest or swamp, whose bitmaps do not exist verbatim anywhere in the
program. A first attempt at the full mountain formula reproduces only 56 of 400
sampled tiles exactly, so `$5922`/`$597E` need reading to the end.

**Consequence for the port:** a 16-entry tile atlas cannot reproduce the
original. Tiles must be selected per position — mountain has 12 variants
(`x & 3` times three slots), forest and swamp 16 each (`x & 3`, `y & 3`) — so
the asset is variants plus an index rule, not one bitmap per terrain.

#### The mountain layout, and two bad refutations of it

`(x & 3) + T[x & 1] + T[y & 1]` with `T` at `$58B4` = `00 24 48 6C` is correct,
and the data layout proves it was designed that way:

```text
mountain region $568B-$571B = 144 bytes = 4 slots of $24
a tile is 32 bytes, so each $24 slot has exactly 4 bytes spare
   T[x & 1] + T[y & 1]  picks slot 0, 1 or 2
   x & 3                shifts 0-3 rows inside the slot's headroom
```

Rendering all twelve combinations gives twelve whole, distinct peaks. Nothing
is sliced.

This was rejected twice, and both rejections were wrong in instructive ways.

**A worthless oracle.** The formula reproduced only 56 of 400 sampled tiles from
the community reference map, which looked decisive. But that map is an atlas
render by another author using one fixed variant — established earlier in these
same notes. A *correct* position-dependent formula can only agree with it where
it happens to emit that variant, roughly one position in eight. 56/400 is 14%.
The measurement was confirming the formula and was read as refuting it.

**A misattributed symptom.** Mountains genuinely looked sliced in the app, which
seemed to settle it. The cause was elsewhere: tile textures were 64 pixels in a
32-point cell, so nearest-neighbour minification was dropping pixel rows at
every zoom below 2.0. Fixing the texture size fixed the "slicing" — but by then
the formula had already been reverted for a crime it did not commit.

The shared lesson: **check that the oracle can answer the question, and that the
symptom belongs to the suspect.**

#### The reference map's annotations are not game data

The reference carries markings the game never draws: **red squares** over 208
tiles and **white circles** over 66. Neither color can come from the exploration
renderer, whose whole palette is yellow, light blue, green and black, and the
terrain vocabulary from the game's own name table at `$1566` has exactly 16
entries with no such thing. They are the map author's annotations — the red
squares mark villages. What the white circles mark is unknown; their tile
coordinates fall in a regular grid, which suggests region markers rather than
anything on the map.

### Terrain colors, measured rather than chosen

Got wrong twice by reaching for a published C64 palette and reasoning about it.
Pepto renders color 7 as a dull olive, Colodore as a bright lemon, and the two
arguments cancelled out. A VICE frame of the running game settles it —
sampling the exploration viewport and taking the brightest member of each
cluster, since VICE darkens alternate scanlines:

| Use      | C64 index | Measured  |
| :------- | :-------- | :-------- |
| plains   | `$07`     | `#EFEB5F` |
| trees    | `$05`     | `#5BBB5B` |
| water    | `$0E`     | `#858FFC` |
| detail   | `$00`     | `#000000` |

Plains really are a bright yellow. The game sets `$D021 = $07` in every view, so
the only question was ever how to render color 7, and a screenshot answers it in
a way that palette arguments do not.

#### The specks in deep water are yellow, and the palette is exact

A **native VICE screenshot** — written by the emulator itself, so no CRT filter
and no display colour management — contains exactly five colours, which makes
the palette above exact rather than estimated:

```text
#030303  black    #7688FF  light blue    #FFFF49  yellow
#65D835  green    #FFFFFF  white (0.09%)
```

The earlier reading of "two blues dithered together" was the CRT filter
darkening alternate scanlines, not the game. There is one blue.

Sampling an open-water region away from the ship shows the specks are
**yellow**, not white: 94.6% blue against 0.086% `#FFFB41`. Water is drawn as
`$55` — every pixel pair `01`, i.e. `$D022` light blue — and the specks are
where a pair is `00` instead, letting `$D021` yellow through. The only white in
the frame is the ship marker, which is a sprite.

Colour RAM is filled uniformly with `$08` across the viewport by the loop at
`$3158`, so bit pattern `11` is black everywhere and nothing is per-terrain.
That closes the question the previous note opened.

What is still missing is the water *pattern*: the speckling lives in the RAM
buffer at `$94B0` that the game animates, not in any static data, so it cannot
be extracted the way the land tiles were. Reproducing it means porting the
animation rather than reading bytes. The deep/medium/shallow distinction and the
shore shapes at charset `$40-$5F` are still unexamined.

### Rendering the map: what went wrong four times

The terrain data was correct throughout. Every fault was in drawing it, and
each was found only because the bug was reported from the running app.

| Symptom | Cause |
| :------ | :---- |
| Mountains sliced, "half mountains and corners" | Applied the `$5922` variant shift literally; `x & 3` moves the source by 1-3 *bytes*, and a byte is a pixel row |
| Woods sparse, everything noisy when zoomed out | Detail art minified to a few pixels; position-varying tiles alias worse than identical ones |
| Grid of dots when zoomed out | Overview tiles were 8 points square in a 32-point cell, so the background showed between them |
| Rivers vanishing at 0.6x-1.2x | Tile textures were 64 pixels in a 32-point cell, so nearest-neighbour minification dropped the two-pixel river line; and tile groups were keyed by position, making 272 near-duplicate groups |

Two rules came out of it.

**Match texture size to cell size.** A 64-pixel texture in a 32-point cell is
minified until zoom 2.0. With nearest-neighbour sampling, minification drops
pixels rather than averaging, so thin features disappear intermittently — which
reads as broken geometry, not as blur. Zoom 1.0 should be 1:1.

**Verify through the path the user is on.** `DumpMode` called `texture(for:)`
with the default `x` and `y`, so every dump rendered variant 0 and exercised a
path the viewer never takes. Renders looked perfect while the app was visibly
broken, twice. It now takes the map position, and `DUMP_X`/`DUMP_Y` so a
reported region can be reproduced exactly.

Zoom matters as much as position: everything checked at 1:1 looked right while
0.26x and 0.63x were wrong, because a 16x16 tile cannot survive being drawn four
pixels wide. Below `detailZoomThreshold` the viewer swaps to flat terrain
colours, which have no fine detail to lose.

### The lesson, twice in one session

The genuine result here — the loader's data path, and stage 1 extracted
statically — came from reading the code that moves the bytes, as always.

But the *wrong* result came the same way, and that is the part worth recording.
Having proved something specific and true about the `$C000` loader, it was
tempting to let it settle a much larger question it did not actually touch.
Verifying the loader says nothing about a file the loader never sees. **Check
that the thing you proved is the thing you needed**, and re-derive a headline
claim from the artifact itself before overturning a prior conclusion — reading
`game`'s own load address and size would have caught this immediately.

4. `$C25A` is the most promising remaining lead. It sets `$2C`/`$2D` to
   `$0800` (low `#$00`, high from `$C003`), then manipulates the 6510 port:

   ```text
   $C263  LDA #$2E / STA $00        ; data direction register
   $C267  LDA $01 / AND #$FE / STA $01   ; clear LORAM — bank out BASIC
   $C26D  LDA #$2F / STA $00
   $C271  LDY #$00 / STY $C2B8
   $C276  LDA ($2C),Y ...
   ```

   So it reads back the loaded data at `$0800` with BASIC banked out. Given
   `$C465` is a rolling checksum and `$C44D` a counter, this is most likely
   verification — but it is the only routine that touches the loaded data in
   bulk, so read it to the end before looking further afield.

#### The walker's validation and unwind

`$19CC` computes `($14 * $14 + $15 * $15) / $21` — a distance metric over the current radius.
`$19EE` wraps it: recompute the radius via `$178A`, take `|metric - radius|`, and return carry set
when that is 3 or more. So it answers **"is this point on the coastline circle"**, with a tolerance
of 3.

`$1A00` is the full candidate test: reject unless `$19EE` accepts, then scan the mask horizontally
from `$0C - $0A` to `$0C` and again from `$0C + 1` to `$0C + 1 + $0A`, rejecting if any bit is
already set. A point must therefore be at roughly the right radius *and* have about ten cells of
clear water either side.

**`$1B3B` clears a mask bit** — `LDA $13D3,X / EOR #$FF / AND ($29),Y / STA ($29),Y`. Land is not
write-once: the walker erases what it drew as it unwinds. An earlier version of `LandMask` asserted
the original had no way to clear a bit, which was wrong; `$1B3B` simply had not been read yet.

`$1A48` erases the current cell and then, in one branch, **patches `$1B38` to `$60` (an `RTS`),
calls `$1A69`, and patches it back to `$4C` (a `JMP`)** — temporarily disabling a routine for the
duration of one call. That is the third distinct self-modification in this phase, after `$22B4`'s
bounds and `$1657`'s `INC`/`DEC`, and like them it has to survive into the port rather than being
tidied into a flag.

`$1A69` steps left and up looking for the edge of existing land, then rewrites the heading `$1A`
from comparisons against `$22` and `$23`/`$24`. It is the wall-following half of the walk.

#### What the walker actually does (traced, `tools/trace_walker.py`)

Reading the routines gave the parts; tracing one fill in the interpreter gives the shape, and it is
not what the routine-by-routine reading suggested.

**The position never moves.** `$22`/`$23:$24` hold the landmass *center*, fixed at the coordinate
the placement loop chose, for the whole fill. `$14`/`$15` are **offsets from it**, and those are
what the walk advances; `$13E0` resolves offset-plus-center at each plot. A port that walks an
absolute position is structurally wrong however faithfully its routines are transcribed.

**The walk traces a circle and modulates its radius.** Starting from `(dx, dy) = (0, radius)`, `dx`
climbs steadily while `dy` drifts noisily downward — `(1,71) (2,70) (3,69) (4,68) ... (22,66)`,
which stays within a cell or two of radius 70 throughout. Meanwhile `$21` climbs 70, 71, 72, 73, 74
as `$178A` recomputes it from the current `dy`. **That is the shape mechanism**: a circle whose
radius is perturbed as it is traced, not a blob roughened afterwards.

**Backtracking is the main loop, not an error path.** One radius-70 fill measured 701 walk
iterations, 716 plots, 155 erases and 155 backtracks — **21.6% of plotted cells are erased again**.
A port treating the unwind as exceptional would build visibly different continents.

**`$1900` was never called** during that fill — not "called and passed". It is called heavily for
smaller features (68 times for a radius-10 island, 530 for a radius-3 fill) and passed every time.
So the restart path stays unobserved, which is consistent with it being rare but is not the same
evidence as a guard being exercised and holding.

**Each continent is followed by a radius-3 fill** that is not registered. For seed `$1234`
configuration 0 the fill sequence is `(166,94)r70`, `(201,93)r3`, `(89,247)r70`, `(106,267)r3`,
`(187,14)r10`, `(190,348)r10` — six fills for four registrations. The satellites sit 20-35 cells
from their continent, well inside its footprint, and islands get none, which fits the `$B0 >= $46`
size test that gates `$178A` and `$17A6` elsewhere.

They **add** land rather than carving it: 23 plots, zero erases, zero backtracks. So they are small
satellite blobs, not lakes — worth knowing before assuming a fill can only grow a landmass.

That also gives an incremental order for porting the walker, easiest first:

| Target             | Walk iterations | Plots | Erases | Backtracks |
| :----------------- | --------------: | ----: | -----: | ---------: |
| radius-3 satellite |              21 |    23 |      0 |          0 |
| radius-10 island   |              91 |    93 |     13 |         13 |
| radius-70 continent|             701 |   716 |    155 |        155 |

The satellite exercises the walk, the plot path and the candidate tests with **no backtracking at
all**, so it isolates the parts that can be got right before the undo ring matters.


#### `$194A` is the interior fill, and `$9100` is shared

The walker traces an outline; it does not fill it. `$194A` does that, and it is a **scanline flood
fill**:

```text
$194E  DEC $22 while the cell is land          ; find the left edge
$1961  INC $22 while it is not                 ; find the span start
$1976  fill leftwards with ORA $13D3,X / STA ($29),Y until a set bit stops it
$198D  seed the row above ($29 -= $20) and below (two $289D), guarded by $1900
$19AE  pop the next span off $9100 and repeat until $46 wraps to $FF
```

So the phase is two stages per landmass: **trace a perturbed circle, then flood its interior**.

**The region at `$9100` is shared, with different record sizes.** `$16BF` computes
`$9100 + $46 * Y` and the stride comes from the caller: `$16BB` passes 12 for the walker's undo
records, while `$19B0` passes 3 for the flood fill's span stack of `(x, pointer low, pointer
high)`. An earlier note here called it "a ring of 201 twelve-byte records" without qualification;
that is only true of the walker's use of it.

This is also where `$1900` earns its bounds guard. The flood fill moves the row pointer up and down
by whole rows, so it is the routine most likely to walk off the buffer — which explains why it is
called 68 times for an island and 530 times for a satellite, and not at all during a continent's
outline trace.

#### The outline walk, end to end

`$15AD` is the loop. Each iteration:

```text
$15B9  INC $46, wrapping to 0 at $C9 (201)      ; ring slot
$15C7  JSR $16BB, then write the undo record    ; $2C-$34, $14, $15, $1A
$15E2  adopt the candidate ($16,$17) as current ($14,$15)
$15EA  JSR $1728                                 ; plot it
$160F  pick $14 or $15 by heading parity ($1A & 1)
$1618  if that coordinate is not yet 0, keep walking this quadrant
$1631  otherwise INC $1A — turn — and JSR $17A6 to adjust $B3
$1642  when $1A reaches 4 the circle is closed; fall into the span fill at $1648
```

So the outline is walked **one quadrant at a time**. The walk starts at
`(dx, dy) = (0, radius)` and advances until the axis coordinate for the current heading reaches
zero, then turns; four turns close the shape. That is why the traced offsets show `dx` climbing
monotonically while `dy` drifts — that is quadrant 0, and the other three are the same walk rotated
by `$13E0`.

Putting the pieces together, a landmass is built in three steps:

1. **Trace** a perturbed circle, four quadrants of biased random walk, backtracking through the undo
   ring whenever `$1A00` rejects a candidate.
2. **Span fill** at `$1648`, with the self-modified `INC`/`DEC` at `$1657` closing each column.
3. **Flood fill** the interior with `$194A`, using `$9100` again as a span stack with a 3-byte
   stride.

A port needs all three. Getting only the first produces coastlines with nothing inside them.

#### The candidate generator at `$24FD` — the other half of the walk loop

`$15AD` is only half of it. `$16B8` does `JMP $24FD`, and that region — which the routine listing
gives no hint belongs to the walker — generates the next candidate before control returns to
`$15AD` to commit it.

```text
$24FD  JSR $178A                     ; recompute $21 and the shape parameters
$2520  compare $14 against $15       ; which axis to advance
$2528    equal -> a coin flip via $0B10 / BMI
$2532  STY $19                       ; 0 = step x, 1 = step y
$2534  LDA $0014,Y / LDY $10 / JSR $0A51 ; the chosen coordinate x $10
$253C  clamp to $FF if the high byte is set
$2542  STA $18                       ; the step threshold
$2544  $44 = $14, $45 = $15          ; candidate starts as current
$254C  JSR $1555 or $1583            ; advance exactly one axis
$2559  JSR $19CC                     ; distance metric, then the $12 / $11 tests
```

Two things this settles.

**The walk always advances its smaller coordinate**, breaking ties with a coin flip. That is what
carries it around the arc: `dx` rises while `dy` falls, and whichever is behind moves next.

**`$18` and `$19` are computed per step, not inherited.** An earlier reading here searched for
writers of `$18`, found them all outside `$14xx`-`$1Bxx`, and concluded they came from another
phase. They come from `$2542`, which *is* in the walk path — just not in the address range the
walker appeared to occupy. `$18` is the chosen coordinate scaled by `$10` (itself `$80 / $0F`), so
the further along an axis the walk has gone, the larger `$18` and the less likely `$1555`/`$1583`
are to step again. That is the mechanism that bends a straight walk into an arc.

So the loop spans two regions: `$15AD`-`$16BB` commits and turns, `$24FD`-`$25A0` proposes. Neither
is comprehensible alone, and nothing in the call graph marks them as one routine.

#### There are two generators, and backtracking rewinds the random state

`$0A9D` is a second LFSR. Byte for byte the same algorithm as `$0AE2` — four `ROL`s, the same two
taps, eight shifts, the same all-zero escape — but on `$1F`/`$20` instead of `$CD`/`$CF`. `$0A87`
is its modulo wrapper, mirroring `$0ACB`. `$27D4` and `$27DE` swap the vectors at `$0B11`/`$0B14`
so the *same* walker code draws from whichever is currently installed:

| Fill                | `$0B10`              | `$0B13`              |
| :------------------ | :------------------- | :------------------- |
| continent, island   | `JMP $0AE2` (`$CD`/`$CF`) | `JMP $0ACB`     |
| satellite           | `JMP $0A9D` (`$1F`/`$20`) | `JMP $0A87`     |

This was found by counting entries to `$0AE2` during each fill: the satellite made **zero**, while
`$1555` unconditionally calls `$0B10`. The routine had not stopped drawing; it was drawing
somewhere else.

**Correction: backtracking does *not* rewind the random state.** An earlier version of this
section claimed it did, reasoning that `$1F`/`$20` sit inside the block `$1B55` copies and that an
unwind therefore restores the generator along with the position. Measured, that is false. Across
every backtrack in a continent fill, the position changes and **neither** generator moves:

```text
before   $1F/$20 = 0,0   $CD/$CF = 73,32   position 2,70
after    $1F/$20 = 0,0   $CD/$CF = 73,32   position 1,71
```

The undo record written at `$15CA` is `$2C`-`$34`, then `$14`, `$15` and `$1A` — nine bytes of
working state plus the position and heading. The generator is not in it, and `$16D1` restores
exactly those twelve bytes. So an unwind rewinds *where* the walk is, not *what it will draw next*:
the retried step gets fresh numbers.

`$1B55`, which copies `$47`-`$4D` into `$1F`-`$25`, is a different mechanism entirely. Its callers
are `$1879` and `$1AED`, neither of which is the backtrack path, and I conflated the two because
both are save-and-restore of a zero-page run.

The two-generator finding above stands — `$0A9D` is real, `$27D4` really does swap the vectors, and
the satellite really does draw from `$1F`/`$20`. Only the consequence I drew from it was wrong. A
port needs both generators; it does not need to snapshot them per step.

The retry loop at `$1564` is also live, not dead code: measured over one continent, stepper calls
consumed one draw 1,106 times, two draws 299 times and three draws once.

### Walker port status

The outline trace is ported and graded against three fills captured from the original
(`walker_reference.json`, via `tools/walker_reference.py`).

| Rung       | Writes | Backtracks | State     |
| :--------- | -----: | ---------: | :-------- |
| satellite  |     23 |          0 | **exact** |
| island     |    106 |         13 | **exact** |
| continent  |    871 |        155 | **exact** |

"Writes" counts plots and erases together, and "exact" means every one of them, in order, to the end
of the fill. The fixture keeps the first 150 events of the continent in full — a port diverges at its
*first* wrong cell, so a prefix is what localizes a fault — plus a SHA-256 over the whole write
sequence, which is what proves the remaining 700. The full stream is not committed: a continent's
cells are generated map data.

Ported and verified: offset resolution `$13E0`, the steppers `$1555`/`$1583`, the shape parameters
`$1731`, radius modulation `$178A`/`$17A6`, the distance metric `$19CC`, candidate validation
`$1A00`, the step evaluator `$1476` with its 3x3 scan, the candidate generator `$24FD`, the direction
mapping `$25B9`, the main loop `$15AD`, the direction search `$2603`, the unwind `$16D1`, the closure
`$1690` and the span fill `$1648`.

### The interior fill, the mirror, and the order they happen in

The outline is only half of a landmass. `$194A` is a scanline flood fill with an explicit stack —
the same `$9100` region and the same `$46` index the undo ring used, reclaimed now that the walk is
over, three bytes an entry. It seeds at the landmass centre, walks right to the first land and back
one, fills leftward while the cells are water, then scans the rows above and below the span it
covered and pushes the rightmost cell of every water run. Two details are worth writing down: the
leftward fill can exit either on land (leaving the index *on* the land cell) or by running down to
column 0 (leaving it at 0, having filled that cell), and the scan span is half open at the left, so
the column the fill stopped on is never scanned. Its one bounds check, at `$1900`, is on the row
*pointer* rather than the row, and failing it is drastic: `JMP $2473` kills the raster interrupt and
restarts the entire land-mass phase.

None of its writes go through `$1728`. It sets bits directly at `$1987`, which is why the walker
fixture — hooked on `$1728` and `$1B3B` — shows no trace of the interior at all.

**Walks and fills are not paired one to one.** A continent's walk does not fill its own interior. At
`$1666` it finds `$54` clear, patches a command into `$0200` and arranges the walk for the satellite
that goes with it; that walk finds `$54` set and reaches `$168D JMP $194A`. The satellite sits inside
the continent's outline, so that single flood fills both, seeded from the continent's centre. Six
walks produce four fills.

### The "satellite" is a lake

Rendering the finished mask settles what `$2629` is actually for, and it is not what the name in this
port suggests. The radius-3 landmass it places sits *inside* the continent's outline, in water the
flood fill has not reached yet. When the fill then runs from the continent's centre it spreads through
everything it can reach — everything except what that little ring encloses. The ring itself is land
surrounded by land and so invisible. What survives is its interior: **a small inland lake, 20 to 43
cells, one per continent, every time.**

Measured across six generated worlds: two continents give two lakes, one continent gives one, with no
exceptions, and each lake's position is the satellite's position carried through the mirror. Since the
port's masks match the original's digests bit for bit, the original does exactly the same.

So `$2629` is the World Maker's inland-water generator, reached through the coastline walker. The code
in this port still calls it a satellite, because that is what `$2794` literally walks — but the effect
is a lake, and it is worth knowing before terrain gets ported on top of it.

**And the map gets mirrored partway through.** `$4500 JSR $1C89` flips two independent coins. On the
first it reverses all 256 bits of every row (`LSR A / ROL` through a scratch buffer at `$9100`,
bytes copied back in the opposite order), mirroring `x` to `255 - x`. On the second it swaps row *r*
with row `399 - r` for *r* from 0 to 199. It runs after the paired continents and before the islands.

That one cost an hour. Every traced write matched the original, every landmass was in the right
place relative to its own centre, and the finished mask was still wrong — by a clean 60-row
translation. Nothing about the mirror goes through the mask's write path, so a replay assembled from
traced writes alone cannot see it. What found it was hooking the interpreter's memory writes rather
than its program counter, and noticing three unfamiliar addresses in the tally: `$1CC6` writing all
12,800 bytes, and `$1D28`/`$1D2D` writing 6,400 each.

`tools/interior_reference.py` records the whole stage as an ordered list of outlines, fills and
mirrors, with a mask digest before each step and one at the end. `InteriorFillTests` replays it from
an empty mask: eleven steps, 31,307 land cells, every write sequence and every digest exact.

### Driving the stage without the fixture

`LandMassStage` is the loop itself — `$2158`'s command table, the placement at `$21B0`-`$227F`, the
walk, the satellite, the fill and the mirror — and it runs from a seed and a configuration alone.
`LandMassStageTests` grades it on all nine seed/configuration pairs the other fixtures use.

The satellite is the interesting part. `$2655` looks for a spot by scanning the column through the
continent's centre for the coast above and below, pulling that window in by two, and then drawing a
row inside it and a column inside the water span of that row (`$28AB`). Rows 185 to 214 are excluded
outright. What it draws has to be at least sixteen cells from the continent's centre on one axis or
the other, and then pass `$22F7` three times, at radii 16, 7 and 12 — which is not the redundancy it
looks like, because `$22F7` samples a cross rather than an area and a smaller radius can fail where a
larger one passed. The seed for its walk comes from a pool of 21 constants at `$229B` that `$1666`
copies to `$0200` with three entries pre-spent, and it walks on the *second* generator with `$1666`
patched to `RTS` so it neither recurses nor floods.

**Where it stops, and why it has to.** `$2277 JSR $44EF` does more than mirror, and what follows is
not land-mass work at all — 573 distinct addresses across `$41E6`-`$47DE` with a tail through
`$1C2A`-`$1E98`. It shares this generator, so it cannot be skipped and it cannot be faked.

### What `$44EF` does after the mirror

It picks **two sites**, filing five zero-page bytes for each — `$77`-`$7B` and `$7C`-`$80`: column,
row, a flag set for rows at or past `$D0`, and a kind that is either 9 or 7, the second always taking
the other (`$46B5 EOR #$0E`). What reads them has not been established. Two positions, far apart, one
of each of two kinds, on land at least 30 cells wide: the shape fits the game's two advanced
civilizations, but that is a guess.

`$4503` measures the mask first: one scan runs down from row 110 for the first row with land and then
on for the first row without, another runs up from row 300 and does the same. Both bands are clamped
into rows 125 to 280, but only where they already straddle those bounds. `$5D` records whether the
two are disjoint — which is to say whether there are two landmasses — and `$45F3` picks the band to
draw from: the first, unless it is under 40 rows and the second is both usable and no worse.

`$4373` draws inside a band and is worth reading carefully. The row comes from two draws in the
*opposite* order to `$247B`: the first supplies the high byte through its sign, the second the low
byte, and the second is redrawn until it comes up **even**. A row outside the band, or one whose
first land run is under 30 cells wide, throws the whole thing away and starts over from the row —
which is why one call can burn dozens of draws. The column then comes from `$22B4` over
`left+9 ..< right-9`; the `+9` is a `+8` plus the carry the width test left set.

`$4479` decides whether two sites are far enough apart: squared distance against 11,968, with each
difference reduced to a **byte** before squaring and the sign taken from the full 16-bit subtraction.
A pair 260 rows apart therefore measures as 4.

There are **two** searches for the second site, and the original picks between them. `$4676`-`$46B9`
runs when the bands are disjoint and a coin flip agrees: draw in the other band, then keep trying
columns inside the land run that row crosses until one is far enough away. Every other time it takes
`$46BC`, which does not sample — it *walks*. It starts at the far end of whichever half of the band
is longer, rounded up to an even row, and steps two rows at a time back toward the first site until
it finds a row whose first land run is at least 30 wide. Then it draws columns there until one is far
enough, and then keeps walking, two rows at a time, for as long as that column stays far enough. The
two ends of that walk bracket a range, a final row is drawn from it, and if the column turns out to
be water in that row it falls back to where the walk began.

`$46BC` does all of this by patching `$4373` in two places, at different times: `$4414` becomes `RTS`
so `$43E7` can be called for the row scan alone, and later `$43E7` becomes `RTS` so what is left of
`$4373` is the row draw alone. `$2139` and `$2143` put both back at the start of every phase.

Then `$47B2` files one more byte, at `$EBCE`, drawn from `$0B16` — **twelve** draws summed, centred
on 1,536, halved as a signed value, scaled and clipped at zero. A rough normal, and the only
non-flat generator found anywhere in the World Maker. Which distribution it uses depends on whether a
second site was found: centred on 1 with spread 1 if so, on 2 with spread 6 if not — and in the
second case, a result of 2 or more overwrites the *first* site's kind with 9.

All of it is ported, and the whole command-table stage now runs from a seed to the original's mask
for configurations 0 and 2. The check is worth describing because it closes a loop: `LandMassStage`
is graded against `interior_reference.json`, captured in the interpreter, and that fixture's final
mask digests agree with `landmass_reference.json`'s — captured months earlier from the real thing
under VICE — on all nine seed and configuration pairs. Two independent captures, one port.

### The second wave

`$215F JMP $280A`, once the command table runs out: two to seven more radius-3 islands, eight to
twelve in configuration 2, scattered anywhere clear rather than placed against anything. Each is
drawn as a radius-10 candidate, retested at radius 5 and only then built at radius 3 — three radii
for one island, which is what keeps them well apart. Rows 195 to 218 are refused outright.

`$281F` patches `$222F` — the `BCS` at the end of the placement loop's clearance test — to `RTS`, so
`JSR $21B8` computes the bounds, draws a position, tests it and returns the carry instead of looping
by itself. The window it computes is the ordinary one for a radius-10 landmass, so the port reuses
`LandMassPhase.bounds` unchanged.

The survivors go into the two position tables, and this settles what they are. Below row 219 an
island is filed into **`$038C`** as `(row, column)`; at or above it goes into **`$03B4`** as
`(row - 192, column)`, keeping the row in a byte. `$03DC` keeps the last column filed either way, and
`$2894` halves `$67` and `$68` to turn each byte offset into a count. Rows 195 to 218 cannot appear
in either, which is why the split boundary and the refusal band do not have to agree. What reads the
tables is still unknown.

The walk itself is the satellite path at `$2794` again, so these islands draw from the second
generator and from the same seed pool — which by this point is pristine, `$167B` having restored it
after the last continent, and which is **not** rebuilt between islands the way `$1666` rebuilds it
between continents.

### Where the land-mass phase stands

Ported end to end for configurations 0 and 2, from a seed to the original's mask, and checked at both
of the phase's checkpoints — `tableStage` and `phaseEnd` — against `landmass_reference.json`, whose
digests were captured from the original under VICE. Nine seed and configuration pairs, two
independent captures, one port.

What is left: configuration 1's paired continent, built by the walk's `$50` mode at `$1860`/`$186C`.
`LandMassStage` refuses that configuration rather than approximating it.

Configuration 1 is refused outright. Its continent is paired, and the partner is not placed by the
placement loop at all — the walk itself reaches `$160C JMP $186C`, saves its state, sets `$50`, and
re-enters `$15AD` for the second landmass. One `$23D3` produces two continents, and one pass of
`$2629` then places two satellites rather than one. None of that is ported.

Five things about this code that no amount of reading the disassembly revealed, all found by diffing
against traces:

- A proposal that moves nothing **re-proposes without plotting** (`$25E6`). Treating it as an
  iteration duplicates the cell.
- The closure at `$1690` fires on `dx < 2`, **not** on `dx` reaching zero.
- The unwind **erases before it restores** (`$16F0` precedes `$16F3`), so the cell cleared is the
  one being stood on.
- `$16D1` returns to `$260B`, **not** to `$2603`. See below.
- The turn at `$1622` **always clears both biases**. See below.
- **Only the horizontal stepper redraws on `$FF`.** `$1564` loops; `$1592` takes what it gets.
- **The closure plots the candidate without adopting it.** `$16AF` passes `$16`/`$17` to `$1728` in
  the registers and leaves `$14`/`$15` alone, so the span fill that follows starts from where the
  walk stands, not from the cell just drawn.

Those last two are a matched pair, in the sense that both are places where two nearly identical
pieces of code differ in one detail, and both stayed hidden for the same reason: they need a
continent that turns with the biases cleared, or a closure whose candidate has moved off the walk's
own position. The satellite and the island never produce either. Each shows up as a single wrong
cell 700-odd writes into a continent, in a different seed and configuration from the one being
tested at the time.

**How the direction search resumes after an unwind.** `$1E` counts attempts, and its invariant is
that it always equals the number of marked slots in the tried set at `$2C`-`$34`. Two are marked
before the search starts: the direction just proposed, and slot 4 — `$25F8 STY $30` files away the
`$FF` the clearing loop left in `Y`, so "no movement" is permanently marked and the picker at `$2619`
can never draw it. Leaving slot 4 free lets a port pick a direction the original would have redrawn
for, which desynchronizes the generator without moving anything.

The invariant is what lets an unwind resume a half-finished search: `$16F6` recounts the restored
record's nonzero flags straight back into `$1E`. And `$2613 JSR $16D1` returns to **`$260B`**, which
is `INC $1E` — not to `$2603`. So every unwind is followed by another increment and another bounds
check, and a restored position that had already tried all nine directions unwinds again immediately.
Missing that extra pass is what left the island stopping one unwind short of the original, resuming
at `(195,12)` where the original resumed at `(196,12)`.

`$16D1` has two non-local exits, both `PLA / PLA`, which discard the `JSR` return address and leave
the search entirely. `$16EC CPX $4F` is the ring-full guard — `$4F` is `$46 + 1`, filed at `$2507`
when the search began, so matching it means unwinding has come the whole way around 201 slots. The
other, at `$16D3`, is the one that actually fires: `$2B` is `$FF` from `$23EA` and is cleared only
when the ring wraps, so `$2B` set with `$46` at zero means every step taken has been undone. From
there the original either restarts the proposal from the origin (`JMP $24FD`, still in the first
quadrant) or gives up on the landmass (`JMP $1A48`).

**The turn's dead draw.** `$1622` draws a random byte and then compares it with `CMP #$00`, which can
only set the carry — so `LDX #$FF` at `$162B` is unreachable and both direction biases are cleared on
every turn. The draw still has to happen; it is the generator that matters, not the value. Guessing a
threshold there (the port had `#$40`) survives the satellite and the island, which never turn with a
radius over `$46`, and shows up 522 writes into a continent.
