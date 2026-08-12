/// The World Maker's land-mass phase — where continents and islands are placed.
///
/// This is the first thing the generator does after clearing memory, and it
/// builds only the 1-bit ``LandMask``; terrain, rivers and villages all come
/// later and read what this leaves behind.
///
/// Transcribed from `$212A` in `game3`. See NOTES.md for how each piece was
/// established and verified against the original.
public enum LandMassPhase {

    // MARK: - The command table

    /// One instruction to the placer: build `count` landmasses of a size class,
    /// with option flags.
    ///
    /// The original stores these as three bytes at `$2286` and reads them with
    /// `$2158`/`$2165`/`$216B`. An earlier reading took the table to be three
    /// seven-byte records of signed motion vectors; it is not. See NOTES.md —
    /// the `$FF` is a bitfield, read only with `BIT`, never as a number.
    public struct Command: Sendable, Equatable {
        /// Selects the radius. The original only tests this for zero.
        public let isContinent: Bool
        /// When set, a second landmass is placed at a fixed offset from the
        /// first and both positions must be clear before either is accepted
        /// (`BIT $43 / BMI` at `$21B0`, and the paired retest at `$2231`).
        public let placesPair: Bool
        /// How many times to run this command (`$55`, decremented at `$2270`).
        public let count: Int
    }

    /// The three worlds the generator can build, chosen by a random byte divided
    /// by 90 (`$2146`-`$2157`), which yields 0, 1 or 2.
    ///
    /// Verified by forcing each one in the original and counting what appeared:
    /// 2+2, 1+2 and 1+6, exactly as these commands predict. Note configuration 1
    /// has `count: 1` and still builds two continents — that is `placesPair`.
    public static let configurations: [[Command]] = [
        [Command(isContinent: true,  placesPair: false, count: 2),
         Command(isContinent: false, placesPair: false, count: 2)],

        [Command(isContinent: true,  placesPair: true,  count: 1),
         Command(isContinent: false, placesPair: false, count: 2)],

        [Command(isContinent: true,  placesPair: false, count: 1),
         Command(isContinent: false, placesPair: false, count: 6)],
    ]

    /// `$2175`: size class zero selects `$46`, anything else `$0A`.
    public static func radius(continent: Bool) -> UInt8 { continent ? 0x46 : 0x0A }

    // MARK: - Placement bounds

    /// Horizontal range a landmass origin may occupy (`$21B8`).
    ///
    /// `x` runs from `size` to `$FE - size`, keeping the whole mass on the map.
    public static func xRange(radius: UInt8) -> (lower: UInt8, upper: UInt8) {
        (radius, 0xFE &- radius)
    }

    /// Vertical range a landmass origin may occupy (`$21B8`, 16-bit).
    ///
    /// `y` runs from `size + 2` to `$0185 - size` — 389 minus the radius, which
    /// is where the map's 400-row height shows up in the arithmetic.
    ///
    /// Configuration 2 overrides this for its single continent, clamping to
    /// 110...220 (`$2208`: `LDA $57 / CMP #$02`), which is why its islands all
    /// land in the lower half.
    public static func yRange(radius: UInt8, config: Int, continent: Bool)
        -> (lower: UInt16, upper: UInt16) {
        if config == 2 && continent { return (0x6E, 0xDC) }
        return (UInt16(radius) &+ 2, 0x0185 &- UInt16(radius))
    }

    // MARK: - The placement test

    /// Whether a landmass of `radius` may be placed centered on (`x`, `y`).
    ///
    /// Transcribed from `$22F7`. Despite sitting where an area test would, this
    /// is **not** one: it samples a *cross* through the bounding box — three
    /// horizontal lines at rows `y - radius`, `y` and `y + radius`, then three
    /// vertical lines at columns `x - radius`, `x` and `x + radius` — and
    /// rejects if any sampled cell is already land. Two landmasses can therefore
    /// overlap without being noticed, which is a property of the original's
    /// output, not a bug to fix.
    ///
    /// Returns `true` to accept (the original clears carry at `$23CF`).
    public static func isClear(x: UInt8, y: UInt16, radius: UInt8,
                              in mask: LandMask) -> Bool {
        // $22F7: right edge, clamped to $FE if x + radius carries past a byte.
        let sum = Int(x) + Int(radius)
        let right = UInt8(sum > 0xFF ? 0xFE : sum)
        // $2302: left edge, floored at 0 on borrow.
        let left = x >= radius ? x - radius : 0
        // $230D: top edge, floored at 0 on borrow, 16-bit.
        let top = y >= UInt16(radius) ? y - UInt16(radius) : 0
        // $232B / $238B: bottom edge. Only clamped once it crosses 256, and then
        // to $8E — so the effective floor of the map here is row 398.
        let rawBottom = y &+ UInt16(radius)
        let bottom = rawBottom > 0xFF && (rawBottom & 0xFF) >= 0x8F
            ? (rawBottom & 0xFF00) | 0x8E : rawBottom

        // $2370: three horizontal lines, columns `left` up to but not including
        // `right`. Both scans are do-while in the original (`INC` then `BCC`),
        // so each runs its body at least once even when the bounds are crossed,
        // and neither samples its far edge.
        var column = left
        repeat {
            if mask.isLand(x: column, y: Int(top)) { return false }
            if mask.isLand(x: column, y: Int(bottom)) { return false }
            if mask.isLand(x: column, y: Int(y)) { return false }
            column &+= 1
        } while column < right

        // $23A3: three vertical lines, rows `top` up to but not including
        // `bottom`.
        var row = top
        repeat {
            if mask.isLand(x: left, y: Int(row)) { return false }
            if mask.isLand(x: right, y: Int(row)) { return false }
            if mask.isLand(x: x, y: Int(row)) { return false }
            row &+= 1
        } while row < bottom
        return true
    }
}
