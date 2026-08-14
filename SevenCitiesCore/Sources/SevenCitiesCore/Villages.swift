/// `$47DF`, the villages.
///
/// The last phase that puts anything on the band, and it starts from somewhere
/// unexpected: the two sites `$44EF` picked out during the mirror, filed in
/// `$77`-`$81` and untouched by everything since. Those become the first two
/// villages. Then one more thrown at random, and then a walk over the map's
/// sixteen-by-sixteen strips placing the rest.
///
/// How many it may place, and how easily, is not decided here — see
/// ``VillageBudget``.
extension TerrainPhases {

    /// One village as the original records it (`$40C8`), alongside the `$F` it
    /// puts on the band.
    public struct Village: Sendable, Equatable {
        public var column: UInt8
        /// `$E900` holds **half** the map row, with the second band's `$C0`
        /// added first — so the table is at half vertical resolution.
        public var halfRow: UInt8
        /// `$EA00`, which `$47DF` sets from the site's own byte for the first
        /// two and from `$42CD` for the rest.
        public var kind: UInt8
    }

    /// `$4428` and `$4441`: may a village go here?
    ///
    /// Two tests. The cell itself has to be land, and a radius-5 box around it
    /// has to be free of `$0F` — which at this point in the pipeline means free
    /// of other villages, the lake marks having been taken back by the second
    /// `$2D23`. The box is scanned **closed** on both axes, unlike the ones in
    /// the water engine.
    static func villageFits(column: UInt8, row: Int, in band: TerrainBand,
                            requireLand: Bool = true) -> Bool {
        if requireLand && band[column, row] < 0x0B { return false }  // $443D
        let area = box(around: column, UInt8(truncatingIfNeeded: row), radius: 5)
        var y = area.top
        while true {
            var x = area.left
            while true {
                if band[x, Int(y)] == 0x0F { return false }          // $4452
                if x == area.right { break }                          // $445C
                x &+= 1
                if x == 0 { break }
            }
            if y == area.bottom { break }                             // $4466
            y &+= 1
        }
        return true
    }

    /// `$40E7`: put the village down and write it into the table at `$E800`.
    static func place(column: UInt8, row: Int, kind: UInt8,
                      in band: inout TerrainBand, into villages: inout [Village],
                      secondBand: Bool) {
        let offset = secondBand ? 0xC0 : 0
        villages.append(Village(column: column,
                                halfRow: UInt8(truncatingIfNeeded:
                                                (row + offset) >> 1),
                                kind: kind))
        band[column, row] = 0x0F                                      // $40F5
    }

    /// `$47E1`: the two sites the mirror chose, and then one at random.
    ///
    /// A site whose own band byte does not match this one is skipped, so each
    /// band places the sites that belong to it. Where a site does belong here,
    /// the phase walks **east** from its column until the ground will take a
    /// village, wrapping and giving up at column zero.
    ///
    /// The random one at `$4823` is the odd case: `$482E` patches `$443F` into
    /// an `RTS` for the length of it, which turns `$4428` into a bare cell test
    /// and lets the draw land on deep water as readily as on land — anything in
    /// `$4` to `$A`, the rivers and the shallows, is what it refuses. `$485C`
    /// puts the branch back.
    static func placeSites(_ sites: SiteSelection.Result,
                           budget: inout VillageBudget.Budget,
                           in band: inout TerrainBand,
                           into villages: inout [Village],
                           rng: inout WorldMakerRNG, secondBand: Bool) {
        func spend() {                                                // $4811
            if secondBand {
                if budget.villages.south != 0 { budget.villages.south &-= 1 }
            } else {
                if budget.villages.north != 0 { budget.villages.north &-= 1 }
            }
        }

        var candidates = [sites.primary]
        // $4817: the second site is only looked at when `$81` is set.
        if sites.parameter != 0, let secondary = sites.secondary {
            candidates.append(secondary)
        }
        for site in candidates where site.southern == secondBand {
            let row = Int(site.row) - (secondBand ? 0xC0 : 0)
            var column = site.column
            var found = false
            while true {                                              // $47F4
                if villageFits(column: column, row: row, in: band) {
                    found = true
                    break
                }
                column &+= 1
                if column == 0 { break }                              // $47FF
            }
            guard found else { continue }
            place(column: column, row: row, kind: site.kind, in: &band,
                  into: &villages, secondBand: secondBand)
            spend()
        }

        // $4823: one more, anywhere the draw lands.
        while true {
            let row = Int(rng.nextByte(from: 0x08, below: 0xCD) & 0xFC)
            let column = rng.nextByte(from: 0x10, below: 0xF0) & 0xFE
            let nibble = band[column, row]
            // $483F: land goes straight on to the box test; so does deep water
            // and the shelf. It is the rivers and shallows that send it round
            // again.
            if nibble < 0x0B && nibble >= 0x04 { continue }
            guard villageFits(column: column, row: row, in: band,
                              requireLand: false) else { continue }
            place(column: column, row: row, kind: 0x0A, in: &band,
                  into: &villages, secondBand: secondBand)            // $484E
            spend()
            return
        }
    }

    /// `$486F`: the strip walk, which places all the rest.
    ///
    /// The same sixteen-by-sixteen strips `$3EAD` uses, but walked **downward**
    /// for the first band — `$0C` starts at `$CF` and is decremented — and
    /// upward for the second. Each strip is quartered and the quarters are taken
    /// bottom-right, bottom-left, top-right, top-left, which is `$0E` counting
    /// down from three.
    ///
    /// A quarter qualifies on twenty land cells out of its sixty-four and on
    /// finding no village already in it. Then a draw has to beat the band's
    /// threshold, and the threshold is **recomputed after every strip** by
    /// `$49BB` from what is left of the budget against what is left of the
    /// eligible ground — so a band that spends its villages early makes the rest
    /// harder to place, and one that has ground to spare makes them easier.
    ///
    /// At most three villages a strip (`$6A`), and a strip that placed none at
    /// all but had three eligible quarters gets one more try across its whole
    /// width at `$4965`.
    ///
    /// **Not finished.** It reproduces the original's first five villages and
    /// then drifts, and the reason is measured rather than guessed: `$49A1`
    /// calls `$4AAB` after every strip, and `$4AAB` is not the pure bookkeeping
    /// it looks like. It surveys the strip's terrain into `$87` onward and sets
    /// region bits in `$EB00`, and then — for any strip that held land at all —
    /// **takes a draw**, and on roughly one in ten goes on to place something
    /// through `$4B91`. One draw a strip is enough to put everything after it
    /// out of step. See TODO.md.
    static func placeAcrossStrips(budget: inout VillageBudget.Budget,
                                  eligible: inout (north: Int, south: Int),
                                  in band: inout TerrainBand,
                                  into villages: inout [Village],
                                  rng: inout WorldMakerRNG, secondBand: Bool) {
        var strip = secondBand ? 0x10 : 0xCF                  // $4865
        // $0E71 writes `$1A` into `$4B83`, the operand of the `CMP` that gates
        // `$4AAB`'s hunt, once per band — and `$4BED` adds **five** to it every
        // time the hunt finds somewhere. So the survey starts willing and gets
        // steadily harder to satisfy as it fills the map in. Reading `CMP #$1A`
        // as a constant is what kept the port from ever running the hunt at all.
        var surveyThreshold: UInt8 = 0x1A

        func remaining() -> UInt8 {
            secondBand ? budget.villages.south : budget.villages.north
        }
        func spend() {
            if secondBand { budget.villages.south &-= 1 }
            else { budget.villages.north &-= 1 }
        }
        func threshold() -> UInt8 {
            secondBand ? budget.threshold.south : budget.threshold.north
        }

        while true {
            let top = UInt8(strip & 0xF0)
            let left = UInt8((strip & 0x0F) * 16)             // $4CCB
            // $4873: the four quarters, in the order `$0E` walks them.
            let quarters = [(top &+ 8, left &+ 8), (top &+ 8, left),
                            (top, left &+ 8), (top, left)]

            var placedHere = 0                                // $6A
            var qualified = 0                                 // $0F
            for (quarterTop, quarterLeft) in quarters {
                // $48AD: land in this quarter, and no village already in it.
                var land = 0
                var blocked = false
                scan: for y in Int(quarterTop)...Int(quarterTop) + 7 {
                    var x = quarterLeft
                    while true {
                        let nibble = band[x, y]
                        if nibble == 0x0F { blocked = true; break scan }
                        if nibble >= 0x0B { land += 1 }
                        if x == quarterLeft &+ 7 { break }
                        x &+= 1
                        if x == 0 { break }
                    }
                }
                if blocked || land < 0x14 { continue }        // $48EC

                qualified += 1                                // $48F5
                // $4900: the quarter is spent whether or not it takes a village.
                if secondBand { eligible.south -= 1 } else { eligible.north -= 1 }

                guard rng.next() > threshold() else { continue }   // $490D
                guard remaining() != 0 else { return }        // $4917
                guard placedHere < 3 else { continue }        // $491B

                var tries: UInt8 = 0
                while true {                                  // $4925
                    let row = rng.nextByte(from: quarterTop,
                                           below: quarterTop &+ 7)
                    if row & 1 != 0 { continue }              // $4931
                    let right = quarterLeft &+ 7
                    let column = rng.nextByte(from: quarterLeft,
                                              below: right == 0xFF ? right
                                                                   : right &+ 1)
                    if villageFits(column: column, row: Int(row), in: band) {
                        place(column: column, row: Int(row), kind: 0,
                              in: &band, into: &villages, secondBand: secondBand)
                        placedHere += 1                       // $433E
                        spend()
                        break
                    }
                    tries &+= 1
                    if tries == 0 { break }                   // $4943
                }
            }

            // $4958: nothing placed here, but the ground was there — one more
            // go, across the strip rather than inside a quarter.
            if placedHere == 0 && qualified >= 3 && remaining() != 0 {
                var tries: UInt8 = 0
                while true {                                  // $4976
                    let row = rng.nextByte(from: top &+ 4,
                                           below: top &+ 15 &+ 2)
                    if row & 1 != 0 { continue }
                    // $498F: `SBC #$02` with the carry left clear by `$4987`'s
                    // `LSR`, so it takes *three* off, not two.
                    let column = rng.nextByte(from: left &+ 3,
                                              below: left &+ 15 &- 3)
                    if villageFits(column: column, row: Int(row), in: band) {
                        place(column: column, row: Int(row), kind: 0,
                              in: &band, into: &villages, secondBand: secondBand)
                        spend()
                        break
                    }
                    tries &+= 1
                    if tries == 0 { break }                   // $499D
                }
            }

            // $49A1: `$4AAB` surveys the strip. None of what it records goes
            // on the band — the counts go to `$87` onward and the positions to
            // `$E600` — but it *draws*, and that is enough to matter. One draw
            // for any strip that held ground at all, and on a low one it hunts
            // for a spot to file, two draws a try.
            var surveyed = false                              // $53
            for (quarterTop, quarterLeft) in quarters {
                for y in Int(quarterTop)...Int(quarterTop) + 7 {
                    var x = quarterLeft
                    while true {
                        if band[x, y] >= 3 { surveyed = true }  // $4B07
                        if x == quarterLeft &+ 7 { break }
                        x &+= 1
                        if x == 0 { break }
                    }
                }
            }
            if surveyed {                                     // $4B77
                let spread = secondBand ? budget.spread.south : budget.spread.north
                if rng.next() < surveyThreshold && spread != 0 {  // $4B82
                    var tries: UInt8 = 0
                    while true {
                        let dy = rng.nextByte(from: 1, below: 0x0F)
                        let dx = rng.nextByte(from: 1, below: 0x0F)
                        let nibble = band[left &+ dx, Int(top) + Int(dy)]
                        if nibble != 0x0F && nibble >= 3 {    // $4BAD
                            if secondBand { budget.spread.south &-= 1 }
                            else { budget.spread.north &-= 1 } // $4BE7
                            surveyThreshold &+= 5              // $4BED
                            break
                        }
                        tries &+= 1
                        if tries == 0 { break }               // $4BB7
                    }
                }
            }

            // $49BB: and the threshold moves with what is left.
            let left_ = secondBand ? eligible.south : eligible.north
            let scaled = VillageBudget.rounded(Int(remaining()) * 10, over: left_)
            let value: UInt8
            if scaled == 0 {
                value = 0xFF                                  // $49D8
            } else {
                let product = VillageBudget.rounded(
                    Int(UInt8(truncatingIfNeeded: scaled)) * 255, over: 10)
                value = UInt8(truncatingIfNeeded: product) ^ 0xFF
            }
            if secondBand { budget.threshold.south = value }
            else { budget.threshold.north = value }

            // $49A4: down for the first band, up for the second.
            if secondBand {
                strip += 1
                if strip >= 0xD0 { return }
            } else {
                strip -= 1
                if strip < 0 { return }
            }
        }
    }

    /// `$4343`: how many villages are already inside a box.
    ///
    /// Half open on both axes, like the water engine's boxes and unlike
    /// `$4441`'s.
    static func villagesIn(_ area: Box, of band: TerrainBand) -> Int {
        var count = 0
        var y = area.top
        while y < area.bottom {
            var x = area.left
            while x < area.right {
                if band[x, Int(y)] == 0x0F { count += 1 }
                x &+= 1
                if x == 0 { break }
            }
            y &+= 1
        }
        return count
    }

    /// `$49F2`: the last few villages, placed on the land rather than on a grid.
    ///
    /// Two passes once the strips are done, and both are outside the `$6C`
    /// budget — which has usually run to zero by now. First every *small*
    /// landmass in the position tables gets villages until it holds three,
    /// retrying as often as it needs to. Then every second-wave island that
    /// holds none at all gets one.
    ///
    /// So the small islands are guaranteed inhabitants the strip walk would
    /// rarely have given them: a sixteen-by-sixteen quarter needs twenty land
    /// cells to qualify, and a ten-radius island spread across four quarters
    /// may not put twenty into any of them.
    static func placeOnLandmasses(_ landmasses: [LandMassStage.Landmass],
                                  _ islands: [LandMassStage.Island],
                                  in band: inout TerrainBand,
                                  into villages: inout [Village],
                                  rng: inout WorldMakerRNG, secondBand: Bool) {
        // $49FA: the same tables `$2E32` reads, and the same split.
        for mass in landmasses where mass.southern == secondBand {
            guard mass.radius < 0x46 else { continue }        // $4A2C
            let row = Int(mass.row)
            // $4A2A: one village, and `$4A46` only comes back here when the
            // spot it drew would not take one. `$4A48` falls through to the
            // next entry rather than looping, so a landmass gets exactly one
            // however much room it has.
            place: while true {
                let area = box(around: mass.column,
                               UInt8(truncatingIfNeeded: row),
                               radius: mass.radius)
                guard villagesIn(area, of: band) < 3 else { break }  // $4A33
                while true {
                    let y = rng.nextByte(from: area.top, below: area.bottom)
                    if y & 1 != 0 { continue }                // $4A3C
                    let x = rng.nextByte(from: area.left, below: area.right)
                    guard villageFits(column: x, row: Int(y), in: band) else {
                        continue place                        // $4A46
                    }
                    self.place(column: x, row: Int(y), kind: 0, in: &band,
                               into: &villages, secondBand: secondBand)
                    break place                               // $4A48
                }
            }
        }

        // $4A4F: and one for every second-wave island that has none.
        for island in islands where island.southern == secondBand {
            let row = secondBand ? Int(island.row) - 192 : Int(island.row)
            guard row >= 0 && row < TerrainBand.rows else { continue }
            let area = box(around: island.column,
                           UInt8(truncatingIfNeeded: row), radius: 5)
            guard villagesIn(area, of: band) == 0 else { continue }  // $4A86
            while true {
                let y = rng.nextByte(from: area.top, below: area.bottom)
                if y & 1 != 0 { continue }                    // $4A8D
                let x = rng.nextByte(from: area.left, below: area.right)
                // $4A9B: no fit test here, only "not water".
                guard band[x, Int(y)] >= 3 else { continue }
                place(column: x, row: Int(y), kind: 0, in: &band,
                      into: &villages, secondBand: secondBand)
                break
            }
        }
    }
}
