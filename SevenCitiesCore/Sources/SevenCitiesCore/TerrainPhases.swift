/// The terrain pipeline — what runs over a ``TerrainBand`` once the land mask is
/// unpacked into it.
///
/// `$0E20` is the pipeline, and it runs once per band:
///
/// | Phase   | What it does                                        |
/// | :------ | :-------------------------------------------------- |
/// | `$2AE9` | marks the second wave's islands, and places something |
/// | `$2D23` | a spread pass, parameterized                        |
/// | `$2E32` | the terrain generator — forest, mountain, shallows   |
/// | `$3961` | river seeds                                         |
/// | `$3EAD` | rivers, and swamp with them                         |
/// | `$2D23` | the same pass again, undoing the marks it laid       |
/// | `$47DF` | villages                                            |
/// | `$4CF2` | leaves the band alone; what it does is unknown       |
/// | `$2C14` | writes the band out                                 |
///
/// Ported so far: the geometry the phases share. The phases themselves are not.
public enum TerrainPhases {

    /// A clamped bounding box around a point (`$2A45`).
    public struct Box: Sendable, Equatable {
        public let left: UInt8, right: UInt8
        public let top: UInt8, bottom: UInt8
    }

    /// The box a phase works within, `radius` either side of a point (`$2A45`).
    ///
    /// The clamps are not symmetric, and that asymmetry is the whole content of
    /// the routine. Horizontally it saturates at 0 and `$FF`, the width of the
    /// map. Vertically it saturates at 0 and **`$CF`** — 207, the last row of the
    /// *band* rather than of the map — which is how every phase downstream stays
    /// inside the 208 rows it was handed without any of them knowing about bands.
    ///
    /// `$2A6D` reaches that ceiling two ways: a carry out of the addition, or a
    /// sum that merely reaches `$D0`. Both land on `$CF`.
    public static func box(around x: UInt8, _ y: UInt8, radius: UInt8) -> Box {
        // $2A47: x - radius, or zero on borrow.
        let left = x >= radius ? x &- radius : 0
        // $2A52: x + radius, or $FF on carry.
        let rightSum = UInt16(x) + UInt16(radius)
        let right: UInt8 = rightSum > 0xFF ? 0xFF : UInt8(rightSum)
        // $2A5D: the same downward for y.
        let top = y >= radius ? y &- radius : 0
        // $2A68: and upward, against the band's height rather than the map's.
        let bottomSum = UInt16(y) + UInt16(radius)
        let bottom: UInt8 = bottomSum >= 0xD0 ? 0xCF : UInt8(bottomSum)
        return Box(left: left, right: right, top: top, bottom: bottom)
    }

    /// Whether swamp is allowed at this row (`$1021`).
    ///
    /// `$3E` gates the fourth outcome of ``scatter(at:row:in:rng:)``, and it is a
    /// **latitude** test: band 0 allows it from row 110 down, band 1 up to row
    /// 108 — which in map coordinates is rows 110 to 299, the middle of the map.
    /// The World Maker puts swamp in the tropics and nowhere else.
    public static func allowsSwamp(bandRow row: UInt8, secondBand: Bool) -> Bool {
        secondBand ? row < 0x6C : row >= 0x6E
    }

    /// Scatters terrain over one cell (`$2BEA`).
    ///
    /// A draw of four decides: `$0C` forest, `$0D` mountain, `$0E` swamp — and the
    /// fourth outcome, which arithmetic would make `$0B` plain, is rewritten to
    /// `$03` instead. Swamp is redrawn rather than taken when the latitude
    /// forbids it, so the gate costs randomness as well as outcomes.
    ///
    /// That `$03` is the same nibble the island marking writes, which is what
    /// settles what `$03` means: **plain, provisionally**. It marks the ground
    /// this phase has been over so later phases can tell it apart, and something
    /// downstream turns it back into terrain — the finished map has none.
    public static func scatter(at column: UInt8, row: Int, in band: inout TerrainBand,
                               rng: inout WorldMakerRNG, secondBand: Bool) {
        var draw: UInt8
        repeat {
            draw = rng.nextModulo(4)                        // $2BF3
        } while draw == 3 && !allowsSwamp(bandRow: UInt8(row), secondBand: secondBand)
        let nibble = draw &+ 0x0B                           // $2C02
        band[column, row] = nibble == 0x0B ? 0x03 : nibble  // $2C07
    }

    /// Scatters terrain around every island in the band (`$28F1`).
    ///
    /// The same radius-10 boxes the marking uses, walked first: every cell that is
    /// **land** — nibble `$3` or above, which at this point means plain — gets a
    /// coin flip, and half of them go through ``scatter(at:row:in:rng:)``. So by
    /// the time `$2B67` marks, most of the plain around an island is gone; that is
    /// why the original marks 165 cells in band 0 where the raw band would give
    /// 308.
    public static func scatterAroundIslands(_ islands: [LandMassStage.Island],
                                            northern: Bool,
                                            in band: inout TerrainBand,
                                            rng: inout WorldMakerRNG,
                                            wrote: (UInt8, Int, UInt8) -> Void = { _, _, _ in }) {
        for island in islands where island.southern == !northern {
            let row = northern ? Int(island.row) : Int(island.row) - 192
            guard row >= 0 && row < TerrainBand.rows else { continue }
            let area = box(around: island.column, UInt8(row), radius: 10)
            for y in Int(area.top)...Int(area.bottom) {
                var x = area.left
                while true {
                    // $2939: below `$3` is water, and water is left alone.
                    if band[x, y] >= 0x03 && Int8(bitPattern: rng.next()) >= 0 {
                        scatter(at: x, row: y, in: &band, rng: &rng,
                                secondBand: !northern)
                    }
                    if x == area.right { break }
                    x &+= 1
                }
            }
            // $295B: an island close to an edge gets no features, and one that is
            // not still only gets them on a coin flip. The shading below happens
            // either way.
            let nearEdge = island.column < 0x0C || island.column >= 0xF4
                || row < 0x0C || row >= 0xC3
            if !nearEdge && Int8(bitPattern: rng.next()) >= 0 {
                placeFeatures(around: island, bandRow: row, in: &band, rng: &rng,
                              secondBand: !northern)
            }
            shadeCoast(around: island, bandRow: row, in: &band, rng: &rng,
                       wrote: wrote)
        }
    }

    /// One more feature, thrown anywhere on the band (`$2AEC`-`$2B3F`).
    ///
    /// After the islands, and on a coin flip, `$2AE9` picks a position at random
    /// rather than from a table — `x` in 11...242, `y` in 11...195 — tests it clear
    /// at radius 10 and again at radius 5, and then runs the same
    /// feature-and-shading pass one more time. Up to 256 tries, and it gives up
    /// quietly.
    ///
    /// Easy to miss: it is 107 shading writes out of 856, all of them nowhere near
    /// any island, which is exactly what an island-driven port cannot account for.
    public static func placeStray(in band: inout TerrainBand,
                                  rng: inout WorldMakerRNG, secondBand: Bool,
                                  wrote: (UInt8, Int, UInt8) -> Void = { _, _, _ in }) {
        for _ in 0..<256 {
            let x = rng.nextByte(from: 0x0B, below: 0xF3)
            let y = rng.nextByte(from: 0x0B, below: 0xC4)
            guard isClear(x: x, y: y, radius: 10, in: band) else { continue }
            guard isClear(x: x, y: y, radius: 5, in: band) else { continue }
            let stray = LandMassStage.Island(column: x, row: UInt16(y),
                                             southern: secondBand)
            placeFeatures(around: stray, bandRow: Int(y), in: &band, rng: &rng,
                          secondBand: secondBand)
            shadeCoast(around: stray, bandRow: Int(y), in: &band, rng: &rng,
                       wrote: wrote)
            return
        }
    }

    /// `$22F7`'s clearance test, run against a band instead of the mask.
    ///
    /// The routine is the same one the land-mass phase uses — the same code, at
    /// the same address. `$2AF1` patches `$141C` and `$1B4E` into `JMP $0FAE` and
    /// `JMP $0FC3`, and `$2B02` rewrites `$13D3` to `F0 0F`, so every `isLand`
    /// underneath it becomes "this nibble is not deep water" without the routine
    /// being touched. Reproducing that in Swift means writing the test twice
    /// rather than patching anything, which is the honest trade.
    ///
    /// The bottom clamp is the map's, not the band's — `$22F7` predates the
    /// band split and still clamps at row 398.
    static func isClear(x: UInt8, y: UInt8, radius: UInt8,
                        in band: TerrainBand) -> Bool {
        func land(_ column: UInt8, _ row: Int) -> Bool { band[column, row] != 0 }

        let sum = Int(x) + Int(radius)
        let right = UInt8(sum > 0xFF ? 0xFE : sum)
        let left = x >= radius ? x - radius : 0
        let top = y >= radius ? y - radius : 0
        let bottom = Int(y) + Int(radius)

        var column = left
        repeat {
            if land(column, Int(top)) || land(column, bottom) || land(column, Int(y)) {
                return false
            }
            column &+= 1
        } while column < right

        var row = Int(top)
        repeat {
            if land(left, row) || land(right, row) || land(x, row) { return false }
            row += 1
        } while row < bottom
        return true
    }

    // MARK: - The coastal shading

    /// How many of the nine cells around one are not deep water (`$2A78`, as
    /// `$2ABC` patches it).
    ///
    /// `$2A78` is one routine with a hole in it. `$2A96` is a branch whose opcode
    /// is rewritten — `$F0` for `BEQ`, `$D0` for `BNE` — and the four bytes at
    /// `$2A98` are the body, copied in from `$2ADB`. `$2ABC` makes it count
    /// non-water; `$2AD5` makes it write water. Same nine cells, opposite jobs.
    static func neighbours(of column: UInt8, _ row: Int,
                           in band: TerrainBand) -> Int {
        var count = 0
        for y in (row - 1)...(row + 1) {
            var x = column &- 1
            for _ in 0..<3 {
                if band[x, y] != 0 { count += 1 }
                x &+= 1
            }
        }
        return count
    }

    /// Shades the deep water around a cell (`$2A78`, as `$2AD5` patches it).
    ///
    /// Every one of the nine that *is* deep water becomes medium (`$1`) or shallow
    /// (`$2`) on a coin flip — unless `flat` is set, which is `$2A02` patching the
    /// `JSR $0AE2` at `$2A9E` into a `BNE` and taking medium every time. That is
    /// the second pass: shallow water shades its own neighbours to medium, and it
    /// would be wrong for those to come out shallow again.
    static func shade(around column: UInt8, _ row: Int, in band: inout TerrainBand,
                      rng: inout WorldMakerRNG, flat: Bool,
                      wrote: (UInt8, Int, UInt8) -> Void = { _, _, _ in }) {
        for y in (row - 1)...(row + 1) {
            var x = column &- 1
            for _ in 0..<3 {
                if band[x, y] == 0 {
                    var value: UInt8 = 1
                    if !flat && Int8(bitPattern: rng.next()) < 0 { value = 2 }
                    band[x, y] = value
                    // `$15` is set once, to the centre row less one, and the row
                    // pointer advances without it — so that is what the original
                    // reports, and what an instrumented comparison must report.
                    wrote(x, row - 1, value)
                }
                x &+= 1
            }
        }
    }

    /// Whether all four diagonal neighbours are deep water (`$2BAA`).
    ///
    /// Carry clear means clear, and the routine gives up early at the band's edges
    /// — row zero and row `$D0` are treated as clear rather than tested.
    static func diagonalsAreWater(around column: UInt8, _ row: Int,
                                  in band: TerrainBand) -> Bool {
        if row != 0 {
            if column != 0 && band[column &- 1, row - 1] != 0 { return false }
            if column &+ 1 != 0 && band[column &+ 1, row - 1] != 0 { return false }
        }
        if row + 1 < TerrainBand.rows {
            if column != 0 && band[column &- 1, row + 1] != 0 { return false }
            if column &+ 1 != 0 && band[column &+ 1, row + 1] != 0 { return false }
        }
        return true
    }

    /// The coastal shading, and the offshore scatter that comes with it (`$2977`).
    ///
    /// Three passes over one island:
    ///
    /// 1. `$2983` — up to `random(10) + 1` extra features, each thrown at a random
    ///    offset up to ten cells away in a random quadrant, and kept only if it
    ///    lands on deep water with fewer than two non-water neighbours and no land
    ///    diagonally. Two hundred and fifty-six tries each before giving up.
    /// 2. `$29D0` — every land cell in a radius-12 box shades the deep water
    ///    around it to medium or shallow, on a coin flip per cell.
    /// 3. `$29FD` — every *shallow* cell in the same box shades its own
    ///    neighbours, flatly, to medium. That is what gives a coast two rings
    ///    rather than one.
    public static func placeFeatures(around island: LandMassStage.Island,
                                     bandRow row: Int, in band: inout TerrainBand,
                                     rng: inout WorldMakerRNG, secondBand: Bool) {
        // $297A: how many features to try for.
        var remaining = Int(rng.nextModulo(10)) + 1
        while remaining >= 0 {
            var tries = 0
            while tries < 256 {
                tries += 1
                // $2987: a quadrant and an offset, resolved the same way the
                // coastline walker resolves its own — `$13E0`, with `$141B`
                // patched to `RTS` by `$28F1` so it stops at the coordinate.
                let heading = rng.next() & 3
                let dy = rng.nextModulo(10)
                let dx = rng.nextModulo(10)
                let (column, target) = CoastlineWalker.cell(
                    offset: .init(dx: dx, dy: dy), heading: heading,
                    centerX: island.column, centerY: UInt16(row))
                guard band[column, target] < 3 else { continue }
                guard neighbours(of: column, target, in: band) < 2 else { continue }
                guard diagonalsAreWater(around: column, target, in: band) else { continue }
                scatter(at: column, row: target, in: &band, rng: &rng,
                        secondBand: secondBand)
                break
            }
            remaining -= 1
        }
    }

    /// The coastal shading (`$29D0`-`$2A32`).
    ///
    /// Two passes over a radius-12 box. The first has every land cell shade the
    /// deep water around it to medium or shallow on a coin flip; the second has
    /// every *shallow* cell shade its own neighbours, flatly, to medium — which is
    /// what gives a coast two rings rather than one.
    ///
    /// **This always runs.** `$295B`'s edge test and `$2972`'s coin flip both jump
    /// to `$296F JMP $29D0`, which is the middle of `$2977` rather than past it —
    /// so what they skip is the feature placement, not the shading. Reading them
    /// as a guard on the whole routine leaves a coast with a fifth of the water it
    /// should have: 131 cells of medium against 644.
    public static func shadeCoast(around island: LandMassStage.Island,
                                  bandRow row: Int, in band: inout TerrainBand,
                                  rng: inout WorldMakerRNG,
                                  wrote: (UInt8, Int, UInt8) -> Void = { _, _, _ in }) {
        let area = box(around: island.column, UInt8(row), radius: 12)
        for pass in 0..<2 {
            for y in Int(area.top)...Int(area.bottom) {
                var x = area.left
                while true {
                    let nibble = band[x, y]
                    if pass == 0 ? nibble >= 3 : nibble == 2 {
                        shade(around: x, y, in: &band, rng: &rng, flat: pass == 1,
                              wrote: wrote)
                    }
                    if x == area.right { break }
                    x &+= 1
                }
            }
        }
    }

    /// Marks the water around every satellite, or unmarks it (`$2D23`).
    ///
    /// One routine, run **twice**, with three bytes inside it rewritten between —
    /// `$0E32` sets them one way and `$0E58` the other. `$2D70` is the operand of
    /// the `CMP` that decides which nibble it is looking for, `$2D74` the operand
    /// of the `LDA` that says what to write, and `$2DA6` is an `LDX` that becomes
    /// an `RTS`. So the first pass turns deep water into `$0F` in a radius-10 box
    /// around each satellite, and the second turns `$0F` back into deep water.
    ///
    /// It marks the sea around the lakes, in other words, so that whatever runs in
    /// between can tell that water apart. Which phase cares is still open — the
    /// terrain generator and the rivers both run inside the marks.
    ///
    /// The positions come from `$0378` and `$0382`, which `$1BF9` fills as the
    /// satellites are placed, split at row **215** — four rows off the 219 the
    /// second wave's islands use, for no reason yet apparent.
    public static func spread(_ satellites: [LandMassStage.Island],
                              northern: Bool, marking: Bool,
                              in band: inout TerrainBand) {
        let looking: UInt8 = marking ? 0x00 : 0x0F
        let writing: UInt8 = marking ? 0x0F : 0x00
        for satellite in satellites where satellite.southern == !northern {
            let row = northern ? Int(satellite.row) : Int(satellite.row) - 192
            guard row >= 0 && row < TerrainBand.rows else { continue }
            let area = box(around: satellite.column, UInt8(row), radius: 10)
            for y in Int(area.top)...Int(area.bottom) {
                var x = area.left
                while true {
                    if band[x, y] == looking { band[x, y] = writing }
                    if x == area.right { break }
                    x &+= 1
                }
            }
        }
    }

    /// The whole of `$2AE9`, the pipeline's first phase.
    ///
    /// Three things, in order, and the middle one is easy to miss:
    ///
    /// 1. `$28F1` — per island: scatter terrain over a radius-10 box, then
    ///    features and coastal shading.
    /// 2. `$2AEC` — on a coin flip, one more of the same at a **random** position
    ///    rather than an island's.
    /// 3. `$2B42` — mark what plain is left inside each island's box as `$3`.
    public static func islands(_ islands: [LandMassStage.Island],
                               northern: Bool, in band: inout TerrainBand,
                               rng: inout WorldMakerRNG) {
        scatterAroundIslands(islands, northern: northern, in: &band, rng: &rng)
        if Int8(bitPattern: rng.next()) < 0 {                // $2AEF BPL $2B42
            placeStray(in: &band, rng: &rng, secondBand: !northern)
        }
        markIslands(islands, northern: northern, in: &band, bandRow: 0)
    }

    /// Marks the second wave's islands (`$2B67`-`$2BA9`).
    ///
    /// For each island the land-mass phase filed into `$038C` or `$03B4`, every
    /// **plain** cell in a radius-10 box around it becomes nibble `$3`. A square,
    /// not a circle — `$2B7B` walks `left...right` inside `top...bottom` and tests
    /// nothing but the nibble already there.
    ///
    /// `$3` does not survive to the finished map: the band still holds 213 cells
    /// of it as late as `$2C14` and the disk has none, so this is scaffolding for
    /// a later phase rather than terrain. Which phase consumes it is still open.
    public static func markIslands(_ islands: [LandMassStage.Island],
                                   northern: Bool, in band: inout TerrainBand,
                                   bandRow: Int,
                                   mark: (UInt8, Int) -> Void = { _, _ in }) {
        for island in islands where island.southern == !northern {
            // The tables hold the row as a byte — `$03B4` stores `row - 192`,
            // which is the same as the row within the second band.
            let row = northern ? Int(island.row) : Int(island.row) - 192
            guard row >= 0 && row < TerrainBand.rows else { continue }
            let area = box(around: island.column, UInt8(row), radius: 10)
            for y in Int(area.top)...Int(area.bottom) {
                var x = area.left
                while true {
                    if band[x, y] == 0x0B {
                        band[x, y] = 0x03
                        mark(x, y)
                    }
                    if x == area.right { break }
                    x &+= 1
                }
            }
        }
    }
}
