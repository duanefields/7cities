/// `$3EAD`, the rivers that start inland.
///
/// The third and last entry into the water engine, and it is not a third
/// routine — it is `$3961`'s walk with three things patched into it before it
/// runs and patched back out afterwards. `$3AA5` becomes `JSR $36CC / JMP
/// $3FB1`, so a finished river is followed by the upstream pass and a cleared
/// mouth table rather than by a distant swamp. `$36A2` becomes `JSR $3FF9`,
/// which refuses to run a river shorter than ten cells out to sea. And `$34DB`
/// is NOPed, which removes `$348D`'s "fewer than two river neighbours" refusal
/// and leaves its other two in place.
///
/// Its own contribution is where the rivers start. It walks the band in
/// **sixteen-by-sixteen strips**, 208 of them, and a strip qualifies only if
/// every cell in it is plain land — no water, no river, no lake mark. Then it
/// shrinks the strip by two on each side, picks a point at random inside it,
/// checks a radius-10 box around that point is land as well, and sources a
/// river there. That is why `$3EAD` draws 21 rivers in the first band against
/// `$3961`'s eight: it is looking for dry interior rather than for lakes.
extension TerrainPhases {

    /// `$3EAD`: every river that starts away from the water.
    public static func inlandRivers(in band: inout TerrainBand,
                                    rng: inout WorldMakerRNG,
                                    engine: inout RiverEngine,
                                    secondBand: Bool) {
        let rules = Rules(refuseShortRuns: true, allowSparse: true,
                          finishWithUpstream: true)
        engine.beginBand()                                    // $3EBF
        var strip: Int = secondBand ? 0x10 : 0                // $3ED2

        while strip < 0xD0 {
            defer { strip += 1 }                              // $3FB8
            guard engine.sources.count < 0x4D else { return }  // $3EDA

            // $3EE2: `$0C`'s high nibble is the strip's row and its low nibble
            // times sixteen is the strip's column.
            var top = UInt8(strip & 0xF0)
            var bottom = top &+ 0x10
            var left = UInt8((strip & 0x0F) * 16)             // $4CCB
            var right = left &+ 0x0F

            // $3EFA: every cell of it has to be plain land.
            guard clear(top..<bottom, left...right, in: band) else { continue }
            guard rng.next() >= 0x32 else { continue }        // $3F23

            // $3F2A: two in from each edge, and a point inside that.
            top &+= 2; bottom &-= 2; left &+= 2; right &-= 2
            let row = Int(rng.nextByte(from: top, below: bottom))
            let column = rng.nextByte(from: left, below: right)

            // $3F44: and a radius-10 box around it, land as well.
            let area = box(around: column, UInt8(truncatingIfNeeded: row),
                           radius: 10)
            guard clear(area.top..<area.bottom, area.left...area.right, in: band)
            else { continue }

            // $3F6F: the same measurement `$3961` makes, and the same rule —
            // the shortest run of at least seventeen wins.
            let runs = landRuns(from: (column, row), in: band,
                                secondBand: secondBand)
            var best: UInt8 = 0xFF
            var heading: UInt8 = 0xFF
            for index in stride(from: 3, through: 0, by: -1) {
                let run = runs[index]
                if run < 0x11 || run >= best { continue }
                best = run
                heading = UInt8(index)
            }
            guard heading != 0xFF else { continue }           // $3F86 BMI

            engine.start(heading: heading, persistence: 0xB4) // $3F8D
            engine.column = column
            engine.row = row
            engine.run(1, in: &band, rng: &rng)               // $4006
            engine.sourceColumn = engine.column
            engine.sourceRow = engine.row
            engine.run(2, in: &band, rng: &rng)               // $3FA9
            walk(&engine, anchor: (row, column), in: &band, rng: &rng,
                 secondBand: secondBand, rules: rules)        // $3FAE
        }
    }

    /// `$3F01` and `$3F52`, which are the same loop: is every cell of this box
    /// plain land?
    ///
    /// Anything below `$0B` fails it and so does `$0F`, so water, river, shore
    /// and the lake marks all disqualify a strip. The column walk stops on a
    /// wrap as well as on the right edge.
    private static func clear(_ rows: Range<UInt8>,
                              _ columns: ClosedRange<UInt8>,
                              in band: TerrainBand) -> Bool {
        var y = rows.lowerBound
        while y < rows.upperBound {
            var x = columns.lowerBound
            while true {
                let nibble = band[x, Int(y)]
                if nibble < 0x0B || nibble == 0x0F { return false }
                x &+= 1
                if x == 0 { break }                           // $3F5F
                if x > columns.upperBound { break }           // $3F63
            }
            y &+= 1
        }
        return true
    }
}
