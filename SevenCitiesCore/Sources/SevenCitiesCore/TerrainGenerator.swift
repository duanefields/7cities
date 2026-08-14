/// `$2E32`, the terrain generator — the largest phase in the pipeline.
///
/// It runs in two halves. First three sweeps of the whole band, each one a plain
/// nested loop over 208 rows and 256 columns:
///
/// 1. `$2E3E` — every **plain** cell pushes shallows out into the water around it.
/// 2. `$2E63` — every shallow cell becomes ocean shelf and drags a run of shelf
///    further out to sea.
/// 3. `$2E92` — every plain cell becomes forest on a draw, against a threshold
///    that moves with latitude.
///
/// Then `$2ED2` walks the landmass tables and draws a range through each — two
/// entirely different drawers, chosen on the radius at `$46`.
///
/// The sweeps and the ranges are independent of each other, which is why they are
/// separable here: nothing the ranges do feeds back into a sweep.
extension TerrainPhases {

    /// `$2E32`, as far as it is ported.
    ///
    /// Everything here is exact. What is missing is `$380D`, the last of the four
    /// stages each landmass goes through, and it is river code rather than
    /// terrain code — it calls the same engine `$3EAD` does. So this leaves the
    /// band short of the original's by whatever the rivers would have put on it,
    /// and every landmass after the first is drawn from a state the original
    /// never had. Do not read the band it produces as finished terrain.
    public static func terrain(_ landmasses: [LandMassStage.Landmass],
                               in band: inout TerrainBand,
                               rng: inout WorldMakerRNG,
                               rivers: inout RiverEngine,
                               secondBand: Bool) {
        coastSweep(in: &band, rng: &rng, secondBand: secondBand)
        shelfSweep(in: &band, secondBand: secondBand)
        forestSweep(in: &band, rng: &rng, secondBand: secondBand)
        ranges(landmasses, in: &band, rng: &rng, secondBand: secondBand,
               rivers: &rivers)
    }

    // MARK: - The first sweep

    /// `$2E3E`: every plain cell shallows the water around it.
    ///
    /// The second band starts at row 16 rather than 0, skipping the sixteen rows
    /// it shares with the first — those already carry the first band's terrain,
    /// and running the sweep over them again would shallow the same coasts twice.
    static func coastSweep(in band: inout TerrainBand, rng: inout WorldMakerRNG,
                           secondBand: Bool) {
        for row in (secondBand ? 16 : 0)..<TerrainBand.rows {
            for column in 0...255 {
                if band[UInt8(column), row] == 0x0B {
                    shallowAround(UInt8(column), row, in: &band, rng: &rng)
                }
            }
        }
    }

    /// `$2C3A`: the shallows around one plain cell.
    ///
    /// A cross five rows tall and three columns wide, minus the cell itself. The
    /// two rows nearest the cell get their middle column from `$2D9E`, which can
    /// write either shallow (`$4`) or shore (`$5`); everything else goes through
    /// `$2D96`, which only ever writes `$4`. So `$5` appears in a plus shape
    /// inside the cross, and only where the water was deep.
    ///
    /// The guards are the original's: column 0 has no left neighbor, column 255 no
    /// right, row 0 no rows above it, and the last row of the band none below.
    /// They are tested against the *stepped* value, so a cell at row 1 gets its
    /// row above but not the row above that.
    private static func shallowAround(_ column: UInt8, _ row: Int,
                                      in band: inout TerrainBand,
                                      rng: inout WorldMakerRNG) {
        // $2C3A: the cell's own row, left and right only.
        if column != 0 { shore(column &- 1, row, from: row, in: &band, rng: &rng) }
        if column != 255 { shore(column &+ 1, row, from: row, in: &band, rng: &rng) }
        // $2C4A: one row up, then two.
        if row != 0 {
            triple(column, row - 1, from: row, center: .shore, in: &band, rng: &rng)
            if row - 1 != 0 {
                triple(column, row - 2, from: row, center: .deep, in: &band, rng: &rng)
            }
        }
        // $2C61: one row down, then two.
        if row + 1 != TerrainBand.rows {
            triple(column, row + 1, from: row, center: .shore, in: &band, rng: &rng)
            if row + 2 != TerrainBand.rows {
                triple(column, row + 2, from: row, center: .deep, in: &band, rng: &rng)
            }
        }
    }

    private enum Middle { case shore, deep }

    /// `$2C83` and `$2C99`, which differ only in what they do to the middle cell.
    private static func triple(_ column: UInt8, _ row: Int, from source: Int,
                               center: Middle, in band: inout TerrainBand,
                               rng: inout WorldMakerRNG) {
        if column != 0 { shallow(column &- 1, row, in: &band) }
        switch center {
        case .shore: shore(column, row, from: source, in: &band, rng: &rng)
        case .deep: shallow(column, row, in: &band)
        }
        if column != 255 { shallow(column &+ 1, row, in: &band) }
    }

    /// `$2D96`: deep water becomes shallow, and nothing else is touched.
    private static func shallow(_ column: UInt8, _ row: Int,
                                in band: inout TerrainBand) {
        if band[column, row] == 0 { band[column, row] = 0x04 }
    }

    /// `$2D9E` into `$2CAF`: deep water becomes shallow, or shore on a draw.
    ///
    /// The latitude test reads `$15`, which is the row of the plain cell that
    /// started this — not the row being written. A cell on row 205 can therefore
    /// put shore on row 207, which the test would have refused on its own behalf.
    private static func shore(_ column: UInt8, _ row: Int, from source: Int,
                              in band: inout TerrainBand,
                              rng: inout WorldMakerRNG) {
        guard band[column, row] == 0 else { return }
        // $2CB2: only draws below $64, and only above the last two rows.
        band[column, row] = rng.next() >= 0x64 || source >= 0xCE ? 0x04 : 0x05
    }

    // MARK: - The second sweep

    /// `$2E63`: shallows become ocean shelf, and drag a run of it out to sea.
    ///
    /// Starts at row **14** for the second band, not the 16 the sweeps either side
    /// of it use. Two rows of the overlap are swept twice as a result, which is
    /// visible in the finished map and is not something a port gets to tidy up.
    static func shelfSweep(in band: inout TerrainBand, secondBand: Bool) {
        for row in (secondBand ? 14 : 0)..<TerrainBand.rows {
            for column in 0...255 {
                let nibble = band[UInt8(column), row]
                if nibble == 0x04 || nibble == 0x05 {
                    shelf(UInt8(column), row, nibble, in: &band)
                }
            }
        }
    }

    /// `$2CDB`: `$4` becomes `$1` and `$5` becomes `$2`, then six cells of `$1`
    /// each way until the run hits anything that is not deep water.
    private static func shelf(_ column: UInt8, _ row: Int, _ nibble: UInt8,
                              in band: inout TerrainBand) {
        band[column, row] = nibble == 0x04 ? 0x01 : 0x02
        for step in [-1, 1] {
            var x = Int(column)
            // $53 counts 5 down through 0: six writes, then the sign bit stops it.
            for _ in 0...5 {
                x += step
                guard x >= 0 && x <= 255 else { break }
                guard band[UInt8(x), row] == 0 else { break }
                band[UInt8(x), row] = 0x01
            }
        }
    }

    // MARK: - The third sweep

    /// `$2E92`: plain becomes forest on a draw, against a moving threshold.
    ///
    /// The threshold is latitude. The first band starts at `$96` and loses one
    /// every even row, so forest thins steadily from the top of the map down; from
    /// row 202 it gains again, which is the first band reaching into the overlap.
    /// The second band starts at `$36` and gains one every even row all the way,
    /// so forest thickens toward the bottom. Between them the map is forested at
    /// both poles and bare across the middle.
    ///
    /// The original would misbehave if the threshold ever reached zero — `$2EC9`
    /// falls through into `$2ECB`, which shifts an already-shifted accumulator.
    /// With these constants it cannot: the first band bottoms out at 50 and the
    /// second tops out at 149.
    static func forestSweep(in band: inout TerrainBand, rng: inout WorldMakerRNG,
                            secondBand: Bool) {
        var row = secondBand ? 16 : 0
        var threshold = secondBand ? 0x36 : 0x96
        while true {
            for column in 0...255 where band[UInt8(column), row] == 0x0B {
                if Int(rng.next()) < threshold { band[UInt8(column), row] = 0x0C }
            }
            row += 1
            if row >= TerrainBand.rows { return }
            guard row % 2 == 0 else { continue }
            // $2EBC: the second band always warms; the first cools until row 202.
            threshold += secondBand || row >= 0xCA ? 1 : -1
        }
    }

    // MARK: - The mountain ranges

    /// `$2ED2`: a mountain range through every landmass in the band's table.
    ///
    /// The table is the one `$1B5F` filed and `$1D42` fixed up — `$0300` for the
    /// first band, `$033C` for the second — and the radius in each entry decides
    /// which of two very different drawers runs. Below `$46` it is a pair of
    /// straight arms thrown out from the center; at `$46` and above it is the
    /// walker at `$2F8C`, which follows the coast.
    @discardableResult
    public static func ranges(_ landmasses: [LandMassStage.Landmass],
                              in band: inout TerrainBand, rng: inout WorldMakerRNG,
                              secondBand: Bool,
                              rivers: inout RiverEngine) -> [Segment] {
        // $5E survives from one landmass to the next — it is zero page, and
        // nothing in $2F8C initializes it. See ``Spine`` for when that shows.
        var west: UInt8 = 0
        var segments: [Segment] = []
        for mass in landmasses where mass.southern == secondBand {
            if mass.radius >= 0x46 {                          // $2F04
                segments += spine(mass, in: &band, rng: &rng, west: &west,
                                  rivers: &rivers, secondBand: secondBand)
            } else {
                armRange(mass, in: &band, rng: &rng, secondBand: secondBand)
                if let count = band.journal?.count {
                    segments.append(Segment(stage: .arms, end: count))
                }
            }
        }
        return segments
    }

    /// Which drawer made a run of writes, matching the names
    /// `tools/range_trace.py` tags the original's with.
    public enum Stage: String, Sendable {
        case arms, spine, spur, clearing, sources
    }

    /// Where one stage's writes end in ``TerrainBand/journal``, so a port that
    /// has some of `$2E32` can be graded on the part it has.
    public struct Segment: Sendable, Equatable {
        public let stage: Stage
        public let end: Int
    }

    /// `$2F0B`: the small-landmass range — two arms of mountain, and swamp.
    ///
    /// Three quadrants are drawn from the landmass center, all distinct: two of
    /// mountain (`$0D`) and, where the latitude allows swamp at all, a third of
    /// swamp (`$0E`). Each arm is `random(2 x radius)` cells long plus fifteen, or
    /// plus twenty for the swamp.
    ///
    /// Nothing walks. Every cell of an arm is thrown independently into the same
    /// quadrant, so an arm is a spray around the center rather than a line — which
    /// is why a small island's mountains look like a blotch and a continent's,
    /// drawn by `$2F8C`, look like a spine.
    private static func armRange(_ mass: LandMassStage.Landmass,
                                 in band: inout TerrainBand,
                                 rng: inout WorldMakerRNG, secondBand: Bool) {
        // $2F0B: how far the throws may reach, above and below. Both bound the
        // horizontal offset as well — there is no separate horizontal clamp.
        let up = min(mass.row, mass.radius)
        let down = min(0xCF &- mass.row, mass.radius)

        let first = rng.next() & 3
        var second = rng.next() & 3
        while second == first { second = rng.next() & 3 }    // $2F29

        // $2F4E counts $26 down from 1, and $0FF8 reads $41,X — so the second
        // direction drawn is the first one used.
        for direction in [second, first] {
            arm(direction, of: mass, up: up, down: down, length: 15,
                nibble: 0x0D, in: &band, rng: &rng)
        }

        guard allowsSwamp(bandRow: mass.row, secondBand: secondBand) else { return }
        var third = rng.next() & 3                           // $2F5B
        while third == first || third == second { third = rng.next() & 3 }
        arm(third, of: mass, up: up, down: down, length: 20,
            nibble: 0x0E, in: &band, rng: &rng)
    }

    /// One arm: `random(2 x radius) + base` cells of `nibble` thrown into a
    /// quadrant. A length of zero would draw 256 — `$2F4A` decrements before it
    /// tests — which these constants cannot produce.
    private static func arm(_ direction: UInt8, of mass: LandMassStage.Landmass,
                            up: UInt8, down: UInt8, length base: UInt8,
                            nibble: UInt8, in band: inout TerrainBand,
                            rng: inout WorldMakerRNG) {
        var count = rng.nextModulo(mass.radius &* 2) &+ base
        repeat {
            let (x, y) = throwInto(direction, from: mass.column, mass.row,
                                   up: up, down: down, in: band, rng: &rng)
            band[x, y] = nibble
            count &-= 1
        } while count != 0
    }

    /// `$0FF8` into `$13E0`: one throw into a quadrant, rejected until it lands
    /// on something that is not open water.
    ///
    /// The four directions are the four quadrants — 0 and 1 go west, 0 and 3 go
    /// north — and the offset within one is drawn twice from the *same* limit:
    /// the room the quadrant has vertically. So the reach is square, and a
    /// landmass near the top or bottom of the band throws short in both axes.
    ///
    /// `$13E0` computes the column as a byte, so an arm thrown from near column 0
    /// or 255 wraps around the map rather than stopping. The row cannot wrap, and
    /// only because the vertical clamps already prevent it.
    ///
    /// Rejection is on the cell already there: below `$3` — deep water and the two
    /// shelves — is redrawn, up to forever. A landmass whose whole reach is water
    /// would spin, and nothing prevents it but the fact that the center is land.
    private static func throwInto(_ direction: UInt8, from column: UInt8,
                                  _ row: UInt8, up: UInt8, down: UInt8,
                                  in band: TerrainBand,
                                  rng: inout WorldMakerRNG) -> (UInt8, Int) {
        let north = direction == 0 || direction == 3
        let limit = (north ? up : down) &+ 1                 // $1009
        while true {
            let dy = rng.nextModulo(limit)
            let dx = rng.nextModulo(limit)
            let x = direction < 2 ? column &- dx : column &+ dx
            let y = north ? Int(row) - Int(dy) : Int(row) + Int(dy)
            if band[x, y] >= 3 { return (x, y) }
        }
    }

    // MARK: - The spine

    /// What the walker at `$2F8C` carries from row to row.
    ///
    /// One field is missing from this and lives in ``ranges(_:in:rng:secondBand:)``
    /// instead: `$5E`, the column of the west coast. `$3003` only writes it when
    /// the westward scan actually reaches water, and `$302F` reads it either way —
    /// so a row of unbroken land from the center to column zero draws from
    /// whatever the *previous* row left there, or from whatever the previous
    /// landmass did. Keeping it outside the walk is what makes that reachable.
    private struct Spine {
        var column: UInt8 = 0       // $14, where the next cell goes
        var row = 0                 // $15
        var limit: UInt8 = 0        // $53, the column this row's run stops at
        var drift: UInt8 = 0        // $13, how far in from the coast to start
        var width: UInt8 = 0        // $19, how long a row's run is
        var life: UInt8 = 0         // $52, rows left before the shape is redrawn
        var widenings: UInt8 = 0    // $1B
        var start: UInt8 = 0        // $16, the column this row's run began at
        var floor: UInt8 = 0        // $25, the row the later stages stop at
        var thinning: UInt8 = 0     // $2C
        var midpoint: UInt8 = 0     // $2D
        var top: UInt8 = 0xFF       // $35, the first row drawn
        var bottom: UInt8 = 0       // $36, the last
        var seen = false            // $5D
        var settled = false         // $76
    }

    /// `$2F8C`: the mountain spine of a continent.
    ///
    /// Where `$2F0B` sprays a small island, this follows the **west coast** down.
    /// Each row it finds where the land begins, steps a little inland, draws a run
    /// of mountain eastward — never past the landmass center — and moves down one.
    /// Every twenty or thirty rows it redraws its own shape, and once in a while
    /// it doubles the width for a stretch, which is what gives a range its
    /// foothills.
    ///
    /// The join at `$306C` is what makes it a range rather than a stack of bars:
    /// after each row it looks along the row *above* for mountain further east
    /// than it reached, and if the gap is five columns or more it extends this
    /// row halfway across and draws again. So the ends stagger into each other.
    private static func spine(_ mass: LandMassStage.Landmass,
                              in band: inout TerrainBand,
                              rng: inout WorldMakerRNG, west: inout UInt8,
                              rivers: inout RiverEngine,
                              secondBand: Bool) -> [Segment] {
        var walk = Spine()
        var segments: [Segment] = []
        func mark(_ stage: Stage) {
            if let count = band.journal?.count {
                segments.append(Segment(stage: stage, end: count))
            }
        }
        walk.row = Int(mass.row)
        // $2F9D: north along the center column until the land runs out.
        while walk.row != 0 {
            if band[mass.column, walk.row] < 3 { break }
            walk.row -= 1
        }
        // $2FAC: fifteen rows back south, and look along that row for mountain
        // some earlier landmass left. Finding it starts the walk there; not
        // finding it starts a little below the coast instead.
        let probeRow = min(walk.row + 15, 0xCF)
        if let found = probe(from: mass.column, along: probeRow, in: band) {
            walk.row = found                                  // $2FC7
        } else {
            walk.row += Int(rng.nextByte(from: 2, below: 11))  // $2FE5
        }
        reshape(&walk, rng: &rng)                             // $2FF0

        while true {
            // $2FF3: no land at the center means the continent has ended.
            guard band[mass.column, walk.row] >= 4 else { break }

            if let coast = coast(from: mass.column, on: walk.row, in: band,
                                 west: &west) {
                walk.column = coast
                if !walk.seen {                               // $3033
                    walk.top = UInt8(walk.row)
                    walk.seen = true
                }
                // $303D: in from the coast by a drifting amount, at least one.
                var inland = rng.nextScattered(around: walk.drift, spread: 2).value
                if inland == 0 { inland = 1 }
                walk.column = walk.column &+ inland
                // $304D: and as far east as the width allows, but never past the
                // center — the spine only ever occupies the western half.
                let span = rng.nextScattered(around: walk.width, spread: 2).value
                let end = span &+ walk.column &+ 1            // $3054's SEC
                walk.limit = end < mass.column ? end : mass.column
                while !advance(&walk, in: &band, rng: &rng) {}

                if !walk.settled {
                    walk.settled = true                       // $3068: not yet
                } else {
                    join(&walk, center: mass.column, in: &band, rng: &rng)
                }
            }

            // $309F
            if walk.row == 0xCF { break }
            walk.row += 1
            walk.life &-= 1
            if walk.life == 0 { reshape(&walk, rng: &rng) }
        }
        walk.bottom = UInt8(walk.row)                         // $30B1
        mark(.spine)
        spur(&walk, of: mass, in: &band, rng: &rng)           // $3134
        mark(.spur)
        clearing(&walk, of: mass, in: &band, rng: &rng)       // $31E6
        mark(.clearing)
        sourceRiver(from: Range(column: mass.column, top: walk.top,
                                bottom: walk.bottom),
                    in: &band, rng: &rng, engine: &rivers,
                    secondBand: secondBand)                   // $380D
        mark(.sources)
        return segments
    }

    /// `$2FC0`: look along a row for mountain already there — west from the
    /// center until the land or the map runs out, then east from the far side.
    private static func probe(from center: UInt8, along row: Int,
                              in band: TerrainBand) -> Int? {
        var column = center
        var west = true
        while true {
            let nibble = band[column, row]
            if nibble == 0x0D { return row }
            if nibble < 3 {
                if !west { return nil }
                west = false
            }
            if west {
                column &-= 1
                if column == 0 { west = false }
            } else {
                column &+= 1
                if column == 0 { return nil }
            }
        }
    }

    /// `$3003`: where this row's run should start, or `nil` if the row already
    /// carries mountain and should be skipped.
    ///
    /// The scan runs west from the center to the coast, then east across the
    /// water and over whatever is on the other side, and settles on the *first*
    /// water it saw. Mountain found in either direction abandons the row.
    private static func coast(from center: UInt8, on row: Int,
                              in band: TerrainBand, west store: inout UInt8)
        -> UInt8? {
        var column = center
        var west = true
        while true {
            let nibble = band[column, row]
            if nibble == 0x0D { return nil }
            if nibble < 3 {
                if west {
                    store = column                            // $3015
                    west = false
                } else {
                    return store                              // $302F
                }
            }
            if west {
                column &-= 1
                if column == 0 { west = false }
            } else {
                column &+= 1
                if column == 0 { return store }
            }
        }
    }

    /// `$30C6`: redraw the walk's shape — how far in from the coast it starts and
    /// how wide it runs — and how many rows before it does so again.
    ///
    /// Twice in a walk, and only twice, a draw below `$23` widens it to a flat 24
    /// instead of scattering around 12. That is the foothill: `$1B` counts the
    /// widenings and the third one cannot happen. Note that this branch takes no
    /// scattered draw at all, which costs the generator twelve fewer advances than
    /// the other two — a port that always scatters desynchronizes here.
    private static func reshape(_ walk: inout Spine, rng: inout WorldMakerRNG) {
        walk.drift = rng.nextScattered(around: 0x0C, spread: 4).value
        if walk.drift == 0 { walk.drift = 1 }                 // $30CF

        if walk.widenings < 2 && rng.next() < 0x23 {          // $30DD
            walk.width = 0x18
            walk.widenings &+= 1
        } else {
            let drawn = rng.nextScattered(around: 0x0C, spread: 2).value
            walk.width = drawn < 4 ? 3 : drawn                // $30F1
        }
        walk.life = walk.width < 0x14 ? 0x14 : 0x1E           // $30F9
    }

    /// `$3104`: one cell of the run, and the step to the next.
    ///
    /// Only plain and forest become mountain; anything else the run passes over
    /// is left alone, so a run that crosses water leaves a gap rather than a
    /// causeway. The step is two columns nine times in ten and one otherwise,
    /// scattered — which is why a run is dotted rather than solid.
    ///
    /// Returns whether the run has reached its limit.
    private static func advance(_ walk: inout Spine, in band: inout TerrainBand,
                                rng: inout WorldMakerRNG) -> Bool {
        let nibble = band[walk.column, walk.row]
        if nibble == 0x0B || nibble == 0x0C { band[walk.column, walk.row] = 0x0D }
        let mean: UInt8 = rng.next() < 0x19 ? 1 : 2           // $3118
        var step = rng.nextScattered(around: mean, spread: 2).value
        if step == 0 { step = 1 }                             // $312A
        walk.column = walk.column &+ step
        return walk.column >= walk.limit                      // $3131
    }

    /// `$306C`: reach east to meet the row above.
    ///
    /// Looks along the previous row from where this one stopped, as far as the
    /// center. Mountain found five or more columns further east extends this row
    /// halfway to it and draws again — and then looks again from there, so a long
    /// reach closes in halves rather than in one jump.
    private static func join(_ walk: inout Spine, center: UInt8,
                             in band: inout TerrainBand,
                             rng: inout WorldMakerRNG) {
        while walk.row != 0 {
            var probe = walk.limit
            var reached: UInt8?
            while true {
                if band[probe, walk.row - 1] == 0x0D { reached = probe; break }
                probe &+= 1
                if probe >= center { break }
            }
            guard let hit = reached else { return }
            let gap = hit &- walk.limit
            guard hit >= walk.limit, gap >= 5 else { return }  // $3090, $3092
            walk.limit = gap / 2 &+ walk.limit
            while !advance(&walk, in: &band, rng: &rng) {}
        }
    }

    // MARK: - What follows the spine

    /// `$319E`: pick a row to start from, a row to stop at, and a shape.
    ///
    /// The starting row is up to half the landmass radius *above* its center, so
    /// the stages after the spine work the same ground from a different place.
    /// The original patches the two immediates this needs — `$31AB` is the floor
    /// on the draw and `$31CE` the mean the shape is scattered around — which is
    /// why they are parameters here.
    private static func settle(_ walk: inout Spine, of mass: LandMassStage.Landmass,
                               mean: UInt8, floor: UInt8,
                               rng: inout WorldMakerRNG) {
        var back: UInt8
        repeat { back = rng.nextModulo(mass.radius >> 1) } while back < floor
        // $31B0: above the center, but never off the top of the band.
        walk.row = mass.row >= back ? Int(mass.row - back) : 2
        let bottom = walk.row + Int(mass.radius)
        walk.floor = bottom >= 0xCF ? 0xCF : UInt8(bottom)    // $31B8
        reshape(&walk, around: mean, rng: &rng)
    }

    /// `$31C9`: the shape one of the later stages draws with.
    ///
    /// Same idea as ``reshape(_:rng:)`` and not the same routine: the width is
    /// scattered around whatever `$319E` patched in, the floor under it is 2
    /// rather than 3, and the drift is scattered around **zero** — which, with
    /// the clamp in `$0B16`, means it is zero most of the time and the run starts
    /// where the last one did.
    private static func reshape(_ walk: inout Spine, around mean: UInt8,
                                rng: inout WorldMakerRNG) {
        walk.life = 0x0F
        let width = rng.nextScattered(around: mean, spread: 2).value
        walk.width = width < 3 ? 2 : width                    // $31D6
        walk.drift = rng.nextScattered(around: 0, spread: 2).value
    }

    /// `$328A`: where the next row's run begins.
    ///
    /// Reads `$03` rather than the value `$0B16` returned, which is the whole
    /// trick: the returned value is clamped at zero, and `$03` still holds the
    /// signed step. So the run wanders both ways from row to row instead of only
    /// east.
    private static func drift(_ walk: inout Spine, rng: inout WorldMakerRNG) {
        let step = rng.nextScattered(around: 0, spread: 2).offset
        walk.column = step &+ walk.drift &+ walk.start
    }

    /// `$3134`: a second range, east of the spine, on a coin flip.
    ///
    /// Only for a landmass with thirty rows of band below it, and only half the
    /// time. It starts a random distance east of the center — nine columns at
    /// least — and runs down the same way the spine does, but with no coast to
    /// follow and no joining: each row simply drifts off the last.
    private static func spur(_ walk: inout Spine, of mass: LandMassStage.Landmass,
                             in band: inout TerrainBand,
                             rng: inout WorldMakerRNG) {
        guard 0xCF - mass.row >= 0x1E else { return }         // $3139
        // $3140 BPL: it proceeds on a *positive* draw. The RTS sits between the
        // branch and its target, so the branch is the go-ahead, not the refusal.
        guard rng.next() < 0x80 else { return }

        var east: UInt8
        repeat { east = rng.nextModulo(mass.radius >> 1) } while east < 9
        walk.column = east &+ mass.column &+ 1                // $314D's carry
        settle(&walk, of: mass, mean: 5, floor: 5, rng: &rng)

        while true {
            let span = rng.nextScattered(around: walk.width, spread: 2).value
            let reach = UInt16(walk.column) + UInt16(span < 3 ? 3 : span)
            walk.limit = reach > 0xFF ? 0xFF : UInt8(reach)   // $3167
            guard band[walk.column, walk.row] >= 0x0B else { return }
            walk.start = walk.column
            while !advance(&walk, in: &band, rng: &rng) {}

            walk.row += 1
            if walk.row >= Int(walk.floor) { return }
            walk.life &-= 1
            if walk.life == 0 {
                guard rng.next() >= 0x19 else { return }      // $3191
                reshape(&walk, around: 5, rng: &rng)
            }
            drift(&walk, rng: &rng)
        }
    }

    /// `$31E6`: the pass that takes the forest back off the mountains.
    ///
    /// It runs down the middle of the landmass turning forest into plain on a
    /// draw, and the draw moves with the row: `$2C` starts at half the height
    /// plus four, falls by one a row until the midpoint and rises after it. So
    /// the clearing is widest at the top and bottom of the range and tightest
    /// across its middle — treeline, in other words, and it is the only thing in
    /// the World Maker that takes terrain away rather than putting it down.
    private static func clearing(_ walk: inout Spine,
                                 of mass: LandMassStage.Landmass,
                                 in band: inout TerrainBand,
                                 rng: inout WorldMakerRNG) {
        settle(&walk, of: mass, mean: 0x1E, floor: 0x0A, rng: &rng)

        // $31F6: west from the center to the coast, or to mountain.
        var column = mass.column
        while column != 0 {
            let nibble = band[column, walk.row]
            if nibble < 0x0B || nibble == 0x0D { break }
            column &-= 1
        }
        // $3205: halfway back toward the center.
        walk.column = mass.column &- ((mass.column &- column) >> 1)
        let half = (walk.floor &- UInt8(truncatingIfNeeded: walk.row)) >> 1
        walk.thinning = half &+ 4                             // $321B
        walk.midpoint = half &+ UInt8(truncatingIfNeeded: walk.row)

        while true {
            let span = rng.nextScattered(around: walk.width, spread: 2).value
            let reach = UInt16(walk.column) + UInt16(span)
            walk.limit = reach > 0xFF ? 0xFF : UInt8(reach)   // $3232
            guard band[walk.column, walk.row] >= 0x0B else { return }
            walk.start = walk.column
            clear(&walk, in: &band, rng: &rng)                // $3268

            walk.row += 1
            if walk.row >= Int(walk.floor) { return }
            if UInt8(truncatingIfNeeded: walk.row) >= walk.midpoint {
                walk.thinning &+= 1
            } else {
                walk.thinning &-= 1
                if walk.thinning == 0 { walk.thinning = 1 }   // $3257
            }
            walk.life &-= 1
            if walk.life == 0 { reshape(&walk, around: 0x1E, rng: &rng) }
            drift(&walk, rng: &rng)
        }
    }

    /// `$3268`: forest back to plain, across one row of the clearing.
    private static func clear(_ walk: inout Spine, in band: inout TerrainBand,
                              rng: inout WorldMakerRNG) {
        while true {
            if band[walk.column, walk.row] == 0x0C,
               rng.next() >= walk.thinning {
                band[walk.column, walk.row] = 0x0B
            }
            walk.column &+= 1
            if walk.column > walk.limit { return }            // $3283
        }
    }
}
