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
                                            rng: inout WorldMakerRNG) {
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
        }
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
