/// `$380D`, the river a mountain range sources.
///
/// It is the last of the four stages `$2E32` runs on a landmass and it is not
/// terrain code: it picks a spot part way down the spine, checks it is clear of
/// the lakes, and hands the position to the river engine that `$3EAD` also
/// drives. On the first band of seed `$1234` it accounts for 5,007 of the 6,601
/// writes the continent takes.
///
/// It only runs where there is a spine to source from — `$3814` refuses a
/// landmass whose walk never drew a row, and `$3822` refuses one whose range is
/// shorter than fifty rows.
extension TerrainPhases {

    /// What `$380D` needs to know about the spine that came before it.
    /// Named for the thing rather than for the shape, because
    /// `Range` is Swift's and shadowing it breaks every other file.
    struct Ridge {
        let column: UInt8          // $22
        let top: UInt8             // $35
        let bottom: UInt8          // $36
    }

    /// `$380D`: source a river from the range, and walk it.
    ///
    /// Returns when the river finishes, is abandoned, or the placement gives up.
    static func sourceRiver(from range: Ridge, in band: inout TerrainBand,
                            rng: inout WorldMakerRNG,
                            engine: inout RiverEngine,
                            secondBand: Bool) {
        guard range.top != 0xFF else { return }               // $3814
        guard range.bottom >= range.top,
              range.bottom &- range.top >= 0x32 else { return } // $3822

        // `$3450` sends a river that unwound to nothing back to the top of this
        // loop, and `$38A6` does the same for a source too close to a lake. The
        // original has no bound on either, so a range where **no** row is
        // acceptable retries for ever — and this is one of the two places the
        // World Maker genuinely hangs, on a C64 as much as here. Confirmed by
        // running the 6502 with its entropy stir intact: two worlds in ninety
        // never finished, at 1.2 billion instructions and a quarter of a million
        // stirs. Fresh randomness cannot help, because what fails is the *map* —
        // every row is within eleven cells of a lake — and a new draw only picks
        // a different row from the same losing set.
        //
        // So this gives up on the range instead of on the world. The row comes
        // from a span of at most 208, so a thousand attempts is five times over
        // having tried every row there is; reaching it means no row will ever do.
        // The landmass loses one river, which is a smaller lie than discarding a
        // finished map. See NOTES.md.
        var attempts = 0
        while !rng.isStuck {
            attempts += 1
            if attempts > 1024 { return }
            // $3826: a row somewhere in the middle twenty rows of the range.
            guard range.bottom >= 0x14 else { return }
            let lower = range.top &+ 0x14                     // $3830's carry
            let upper = range.bottom &- 0x14
            guard lower < upper else { return }
            var row = Int(rng.nextByte(from: lower, below: upper))

            // $3842: west from the landmass centre until the land runs out, then
            // east again to the first mountain.
            var column = range.column
            while column != 0 {
                if band[column, row] < 3 { break }
                column &-= 1
            }
            while band[column, row] != 0x0D {                 // $3851
                column &+= 1
                if column == 0 { break }
            }
            // $385C: and then past it — up to six cells of anything that is not
            // mountain, which puts the source on the range's far shoulder.
            var clear: UInt8 = 0
            while true {
                if band[column, row] == 0x0D {
                    clear = 0
                } else {
                    clear &+= 1
                    if clear == 6 { break }
                }
                column &+= 1
                if column == 0 { break }
            }
            column = column &+ (rng.next() & 3)               // $3875

            // $387E: not here if a lake is anywhere within eleven cells.
            let area = box(around: column, UInt8(truncatingIfNeeded: row),
                           radius: 11)
            if !unmarked(area, in: band) { continue }         // $38A6

            // $38BB: east, and one step to get going.
            engine.start(heading: 2)                          // $32CC
            // $38C3 and $38C8, *after* `$32CC` has already read the old values.
            engine.patchedAllowance = 0x0A
            engine.patchedPersistence = 0xAA
            engine.column = column
            engine.row = row
            engine.run(1, in: &band, rng: &rng)               // $4006
            engine.sourceColumn = engine.column               // $4011 into $76
            engine.sourceRow = engine.row                     // $400D into $37
            engine.landmassColumn = range.column

            // $3450 jumps back to $380D itself: a river that unwinds to
            // nothing is not the end of the attempt, it is the end of *this*
            // attempt, and the whole placement runs again from a new row.
            if walk(&engine, in: &band, rng: &rng, secondBand: secondBand) {
                return
            }
        }
    }

    /// `$38CD`: one river, a step at a time.
    ///
    /// Every step is checked three ways before it is taken — the row it lands
    /// on, the cell itself, and a fan of three directions seven cells deep — and
    /// any of them failing sends the walk into `$33EF` to take the river back.
    /// Returns true when the river finished — reached the sea — and false when
    /// it unwound to nothing and the placement should start again.
    @discardableResult
    private static func walk(_ engine: inout RiverEngine,
                             in band: inout TerrainBand,
                             rng: inout WorldMakerRNG, secondBand: Bool) -> Bool {
        var turns = 0
        while !rng.isStuck {
            turns += 1
            // Abandoned rather than finished, so `$380D`'s retry counts it and
            // eventually gives up on the range instead of cycling here for ever.
            if turns > RiverEngine.walkTurnLimit { return false }
            let stop = engine.index &+ 1                      // $38CD
            engine.stopIndex = stop
            engine.choose(rng: &rng)                          // $38D2
            engine.aim(rng: &rng)

            // $38D5: the second band may not step onto row 1, the first may not
            // step onto row $CE or below.
            let offEdge = secondBand ? engine.nextRow == 1 : engine.nextRow >= 0xCE
            var give = offEdge

            if !give {
                let nibble = band[engine.nextColumn, engine.nextRow]
                if nibble < 3 {
                    // $38EB into $36CC and $3E53, which are not ported. The
                    // river stops here instead of finishing into the sea.
                    return true
                }
                if nibble == 0x0F || nibble < 0x0B { give = true } // $38FB
            }

            var reachedSea: UInt8?
            if !give {
                switch ahead(engine, in: band, secondBand: secondBand) {
                case .clear: break
                case .blocked: give = true
                case .sea(let direction): reachedSea = direction
                }
            }
            if let direction = reachedSea {
                finish(&engine, probe: direction,
                       source: (engine.sourceColumn, engine.sourceRow),
                       in: &band, rng: &rng, secondBand: secondBand)
                return true                                   // $3959
            }
            if !give && !engine.clearOfLakes(in: band) { give = true } // $394B

            if give {
                if engine.erase(allowance: engine.patchedAllowance, stop: stop,
                                in: &band, rng: &rng) == .exhausted {
                    return false                              // $3450
                }
                continue                                      // $348A into $38CD
            }

            engine.take(in: &band)                            // $3950
            _ = engine.fileMouth(in: &band, sourcesFull: false) // $3953
        }
        return true                                           // stuck: no retry
    }

    /// `$3903`: look along the three directions that are not a reversal, seven
    /// cells each, and refuse the step if any of them runs into a lake mark or
    /// off the land.
    ///
    /// Water found is not a refusal — it is the sea, and `$3959` finishes the
    /// river into it with `$369F` and `$3E53`. **That finish is not ported
    /// yet**, so this returns as if the way were clear and the walk carries on
    /// past where the original stops. It is worth 32 cells of `$0E` in the first
    /// band, and it is the last thing missing from `$380D`.
    enum Ahead { case clear, blocked, sea(UInt8) }

    private static func ahead(_ engine: RiverEngine, in band: TerrainBand,
                              secondBand: Bool) -> Ahead {
        for probe in 0..<3 {
            let direction = RiverEngine.lookahead[Int(engine.last) * 4 + probe]
            guard direction != 0xFF else { continue }
            let step = RiverEngine.steps[Int(direction) / 2]
            var x = engine.nextColumn
            var y = engine.nextRow
            for _ in 0..<7 {
                x = x &+ UInt8(bitPattern: step.dx)
                if x == 0 { break }                           // $391C CPX #$00
                y += Int(step.dy)
                // $3920: the same edge the walk itself is held to.
                if secondBand ? y < 1 : y >= 0xCE { break }
                let nibble = band[x, y]
                if nibble == 0x0F { return .blocked }         // $3931
                if nibble < 3 { return .sea(direction) }      // $3935
                if nibble < 0x0B { return .blocked }          // $3939
            }
        }
        return .clear
    }

    // MARK: - Finishing

    /// `$3959` into `$38EB`: run the river out into the sea and be done.
    ///
    /// Three things happen and none of them is another step of the walk.
    /// `$369F` carries the water the last few cells to the shore. `$3755` files
    /// both ends of the river into the table at `$E681` — the source, the mouth,
    /// and the length once positive and once negated. And then the swamp: one
    /// blob where the river met the sea, and a second one ten to twenty-nine
    /// rows away, both through `$3D97`.
    ///
    /// `$38EE` also leaves the engine set up for whoever runs next — the erase
    /// allowance drops to six and the persistence rises to `$B4`, and neither is
    /// put back.
    private static func finish(_ engine: inout RiverEngine, probe direction: UInt8,
                               source: (column: UInt8, row: Int),
                               in band: inout TerrainBand,
                               rng: inout WorldMakerRNG, secondBand: Bool) {
        // $38EE and $38F3: the finish leaves both operands changed for whatever
        // runs next, and nothing puts them back.
        engine.patchedAllowance = 0x06
        engine.patchedPersistence = 0xB4
        carry(&engine, direction: direction, until: 3, in: &band, rng: &rng)
        engine.fileSource(from: source.column, source.row, secondBand: secondBand)

        // $37B7: a `$4` underfoot means the river ended on a shallow, and the
        // swamp goes down where it stands rather than off to one side.
        if engine.tile == 0x04 {
            let radius = rng.nextByte(from: 4, below: 8)      // $3D90
            swamp(radius: radius, at: engine.column, engine.row, in: &band,
                  rng: &rng, secondBand: secondBand)
        } else {
            shiftAndSwamp(&engine, source: source.column, in: &band, rng: &rng,
                          secondBand: secondBand)             // $3E8B
        }
        distantSwamp(&engine, in: &band, rng: &rng, secondBand: secondBand)
    }

    /// `$369F`: keep stepping the one way until the cell ahead is water.
    ///
    /// The heading never changes, so this is a straight line: a vertical one
    /// leaves the band inside 208 steps and reads 0, which is under every
    /// threshold, but a horizontal one wraps at column 255 and would lap a row
    /// of unbroken land forever. It does not draw while it does that — `$33B7`
    /// only redraws when the aim fails, and the aim here cannot — so the lap
    /// bound has to say so itself. See ``WorldMakerRNG/declareStuck()``.
    private static func carry(_ engine: inout RiverEngine, direction: UInt8,
                              until threshold: UInt8,
                              in band: inout TerrainBand,
                              rng: inout WorldMakerRNG) {
        let heading = direction / 2
        // $36A2: the first step reuses the destination the walk had already
        // worked out, but records this direction and its tile.
        engine.chosen = heading
        engine.tile = RiverEngine.tiles[Int(heading) * 4 + Int(engine.last)] ?? 0
        for _ in 0..<256 {
            engine.take(in: &band)                            // $36B4
            engine.chosen = heading                           // $36B7
            engine.aim(rng: &rng)
            if band[engine.nextColumn, engine.nextRow] < threshold { return }
        }
        rng.declareStuck("$369F carry")
    }

    /// `$3E8B`: a swamp four to seven cells to one side of the river's end.
    static func shiftAndSwamp(_ engine: inout RiverEngine,
                                      source: UInt8, in band: inout TerrainBand,
                                      rng: inout WorldMakerRNG,
                                      secondBand: Bool) {
        let radius = rng.nextByte(from: 4, below: 8)
        var column = engine.column
        // $3E94: away from the source, or toward it if that would underflow.
        if source >= column || column < radius {
            column = column &+ radius
        } else {
            column = column &- radius
        }
        swamp(radius: radius, at: column, engine.row, in: &band, rng: &rng,
              secondBand: secondBand)
    }

    /// `$3E53`: a second swamp, well away from the river.
    static func distantSwamp(_ engine: inout RiverEngine,
                                     in band: inout TerrainBand,
                                     rng: inout WorldMakerRNG,
                                     secondBand: Bool) {
        var offset = rng.nextByte(from: 0x0A, below: 0x1E)    // $3E53
        if Int8(bitPattern: rng.next()) >= 0 {                // $3E5F BMI
            offset = 0 &- offset
        }
        let row = Int(UInt8(truncatingIfNeeded: engine.row) &+ offset)
        guard row < 0xCF else { return }                      // $3E70
        engine.row = row

        // $3E74: east from the landmass centre to the first water.
        var column = engine.landmassColumn
        guard band[column, row] >= 4 else { return }          // $3E7D
        while band[column, row] >= 3 {                        // $3E7F
            column &+= 1
            if column == 0 { return }
        }
        engine.column = column
        shiftAndSwamp(&engine, source: engine.sourceColumn, in: &band, rng: &rng,
                      secondBand: secondBand)
    }

    /// `$3D97`: a blob of swamp, thrown into a box.
    ///
    /// `radius * radius * 2` cells, each one drawn at random inside a box of
    /// that radius and kept only where the ground is land that is not already
    /// swamp or a lake mark — up to 256 tries each. It refuses the whole thing
    /// where the latitude forbids swamp, and again on a draw against three times
    /// the distance from the middle of the map, so swamp thins toward the poles
    /// rather than stopping at a line. And it gives up before it starts if the
    /// box already holds ten mountains or ten swamps.
    static func swamp(radius: UInt8, at column: UInt8, _ row: Int,
                      in band: inout TerrainBand, rng: inout WorldMakerRNG,
                      secondBand: Bool) {
        var count = UInt8(truncatingIfNeeded: Int(radius) * Int(radius) * 2)
        guard allowsSwamp(bandRow: UInt8(truncatingIfNeeded: row),
                          secondBand: secondBand) else { return }
        // $3DAB: how far this row is from the middle of the map, tripled.
        let mapRow = (Int(row) + (secondBand ? 0xC0 : 0)) >> 1
        let distance = UInt8(truncatingIfNeeded: abs(0x66 - mapRow))
        let threshold = UInt8(truncatingIfNeeded: Int(distance) * 3)
        guard rng.next() >= threshold else { return }         // $3DCC

        let area = box(around: column, UInt8(truncatingIfNeeded: row),
                       radius: radius)
        // $3DE7: ten of either and this ground is spoken for. The box is half
        // open on *both* axes here — `$3E1B` and `$3E23` are both `BCC` — so
        // neither the right column nor the bottom row is counted. Counting the
        // bottom row is worth ten mountains on a range's flank, and a swamp
        // that should have been placed is not.
        var mountains = 0, swamps = 0
        var y = area.top
        while y < area.bottom {
            var x = area.left
            while true {
                switch band[x, Int(y)] {
                case 0x0D:
                    mountains += 1
                    if mountains >= 10 { return }
                case 0x0E:
                    swamps += 1
                    if swamps >= 10 { return }
                default: break
                }
                x &+= 1
                if x == 0 { break }                           // $3E19
                if x >= area.right { break }                  // $3E1B
            }
            y &+= 1
        }

        while count != 0 {
            var tries: UInt8 = 0
            while true {
                let candidate = rng.nextByte(from: area.top, below: area.bottom)
                let at = rng.nextByte(from: area.left, below: area.right)
                let nibble = band[at, Int(candidate)]
                if nibble >= 0x0B && nibble != 0x0F && nibble != 0x0E {
                    band[at, Int(candidate)] = 0x0E           // $3E49
                    break
                }
                tries &+= 1
                if tries == 0 { break }                       // $3E45
            }
            count &-= 1
        }
    }
}


extension TerrainPhases {

    /// Whether a box holds no lake mark (`$3897` and `$3506`, which are the
    /// same loop twice).
    ///
    /// **The box is half open.** `$38A9` and `$3515` step the column and then
    /// compare it against `$04` with `BCC`, so the right-hand column is never
    /// looked at, and `$38B3` and `$351F` do the same to the bottom row. Every
    /// other box in the World Maker — the marking, the spread, the scatter — is
    /// closed on all four sides, so this reads like a slip rather than a design,
    /// and it is worth 1,745 writes into a river before it shows.
    static func unmarked(_ area: Box, in band: TerrainBand) -> Bool {
        var y = area.top
        while y < area.bottom {
            var x = area.left
            while x < area.right {
                if band[x, Int(y)] == 0x0F { return false }
                x &+= 1
                if x == 0 { break }                           // $38AD, $3518
            }
            y &+= 1
        }
        return true
    }
}
