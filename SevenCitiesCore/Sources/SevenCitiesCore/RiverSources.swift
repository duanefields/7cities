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
    struct Range {
        let column: UInt8          // $22
        let top: UInt8             // $35
        let bottom: UInt8          // $36
    }

    /// `$380D`: source a river from the range, and walk it.
    ///
    /// Returns when the river finishes, is abandoned, or the placement gives up.
    static func sourceRiver(from range: Range, in band: inout TerrainBand,
                            rng: inout WorldMakerRNG,
                            engine: inout RiverEngine,
                            secondBand: Bool) {
        guard range.top != 0xFF else { return }               // $3814
        guard range.bottom >= range.top,
              range.bottom &- range.top >= 0x32 else { return } // $3822

        while true {
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
            engine.start(heading: 2, persistence: 0xAA)
            engine.column = column
            engine.row = row
            engine.run(1, in: &band, rng: &rng)               // $4006
            let sourceColumn = engine.column                  // $4011 into $76
            let sourceRow = engine.row                        // $400D into $37
            _ = (sourceColumn, sourceRow)

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
        while true {
            let stop = engine.index &+ 1                      // $38CD
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

            if !give && !ahead(engine, in: band, secondBand: secondBand) {
                give = true
            }
            if !give && !engine.clearOfLakes(in: band) { give = true } // $394B

            if give {
                if engine.erase(allowance: 0x0A, stop: stop, in: &band,
                                rng: &rng) == .exhausted {
                    return false                              // $3450
                }
                continue                                      // $348A into $38CD
            }

            engine.take(in: &band)                            // $3950
            _ = engine.fileMouth(in: &band, sourcesFull: false) // $3953
        }
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
    private static func ahead(_ engine: RiverEngine, in band: TerrainBand,
                              secondBand: Bool) -> Bool {
        for probe in 0..<3 {
            let direction = RiverEngine.lookahead[Int(engine.last) * 4 + probe]
            guard direction != 0xFF else { continue }
            let step = RiverEngine.steps[Int(direction) / 2]
            var x = engine.nextColumn
            var y = engine.nextRow
            for _ in 0..<7 {
                x = x &+ UInt8(bitPattern: step.dx)
                y += Int(step.dy)
                // $3920: the same edge the walk itself is held to.
                if secondBand ? y < 1 : y >= 0xCE { break }
                let nibble = band[x, y]
                if nibble == 0x0F { return false }            // $3931
                if nibble < 3 { return true }                 // $3935: the sea
                if nibble < 0x0B { return false }             // $3939
            }
        }
        return true
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
