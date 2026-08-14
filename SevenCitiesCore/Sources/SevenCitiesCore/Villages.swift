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
}
