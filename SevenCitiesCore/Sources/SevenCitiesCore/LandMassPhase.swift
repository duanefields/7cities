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

    /// The window a landmass origin may be drawn from.
    public struct Bounds: Sendable, Equatable {
        public let xLower: UInt8, xUpper: UInt8
        public let yLower: UInt16, yUpper: UInt16
    }

    /// Bounds for one placement (`$21B8` and `$21CD`).
    ///
    /// The unpaired case is the simple one: `x` in `radius ..< $FE - radius` and
    /// `y` in `radius + 2 ..< $0185 - radius`, which keeps the mass on the map
    /// and is where the 400-row height shows up in the arithmetic.
    ///
    /// **The paired case moves two of the four bounds**, and missing either puts
    /// the second landmass off the map:
    ///
    /// - `xLower` becomes `pairOffset + radius`, because the partner is placed
    ///   at `x - pairOffset` and needs room to the left.
    /// - `yUpper` becomes `$0185 - (3 * radius + radius / 8)` rather than
    ///   `$0185 - radius`, because the partner sits `2 * radius + radius / 8`
    ///   further down.
    ///
    /// Configuration 2 then overrides both vertical bounds for its continent,
    /// clamping to `110 ..< 220` (`$2202`/`$2208`), which is why its islands all
    /// end up in the lower half of the map.
    public static func bounds(radius: UInt8, paired: Bool, pairOffset: UInt8,
                              config: Int) -> Bounds {
        let xUpper = 0xFE &- radius
        var xLower = radius
        var yLower = UInt16(radius) &+ 2
        var yUpper = 0x0185 &- UInt16(radius)

        if paired {
            xLower = pairOffset &+ radius
            let spread = UInt16(radius) &* 3 &+ UInt16(radius) / 8
            yUpper = 0x0185 &- spread
        }
        // $2202: only continents, and only in configuration 2.
        if radius >= 0x46 && config == 2 {
            yLower = 0x6E
            yUpper = 0xDC
        }
        return Bounds(xLower: xLower, xUpper: xUpper,
                      yLower: yLower, yUpper: yUpper)
    }

    // MARK: - The placement loop

    /// One accepted landmass.
    public struct Placement: Sendable, Equatable {
        public let x: UInt8
        public let y: UInt16
        /// The command's nominal radius — `$B0`, not `$21`. See NOTES.md: `$21`
        /// is a scratch copy that sometimes drifts by one, for reasons not yet
        /// established.
        public let radius: UInt8
        /// The partner, when the command placed a pair.
        public let partner: (x: UInt8, y: UInt16)?

        public static func == (a: Placement, b: Placement) -> Bool {
            a.x == b.x && a.y == b.y && a.radius == b.radius
                && a.partner?.x == b.partner?.x && a.partner?.y == b.partner?.y
        }
    }

    /// Runs the command-table stage: `$2173` through `$227F`.
    ///
    /// `fill` is called for each accepted landmass and is where the coastline
    /// walker goes. It matters for more than appearance — later placements are
    /// tested against what earlier ones drew, so with an empty `fill` every
    /// candidate is accepted on its first try and only the *first* placement of
    /// a run can be compared against the original.
    ///
    /// ### Draws that look skippable and are not
    ///
    /// `pairOffset` and the `$B1`/`$B2` coin flip are both drawn **before** the
    /// code knows whether it needs them, and both are then overwritten in the
    /// common path — `pairOffset` with `$FF` for unpaired commands (`$21B4`) and
    /// the coin flip with `$FF`/`$80` for islands (`$21A8`). They still advance
    /// the generator, so omitting them desynchronizes every later draw.
    public static func runCommandStage(
        config: Int,
        rng: inout WorldMakerRNG,
        mask: inout LandMask,
        fill: (UInt8, UInt16, UInt8, inout LandMask) -> Void = { _, _, _, _ in }
    ) -> [Placement] {
        var placed: [Placement] = []

        for command in configurations[config] {
            let radius = self.radius(continent: command.isContinent)

            for _ in 0..<command.count {
                // $2183: shape parameters. Only $0F is needed here, and none of
                // this consumes randomness.
                let motionLimit = UInt8((UInt16(radius) &* 5) / 7)

                // $2186: drawn unconditionally, redrawn while it lands on 1.
                var pairOffset: UInt8
                repeat {
                    pairOffset = rng.nextModulo(motionLimit) &+ 1
                } while pairOffset == 1

                // $2193: drawn unconditionally; the result is discarded for
                // islands at $21A8 and unused here either way.
                _ = rng.next()

                // $21B0: the offset only survives for a paired command.
                if !command.placesPair { pairOffset = 0xFF }

                let b = bounds(radius: radius, paired: command.placesPair,
                               pairOffset: pairOffset, config: config)

                // $221C: up to 256 attempts, the counter wrapping at $2281.
                var attempts = 0
                while attempts < 256 {
                    attempts += 1
                    let x = rng.nextByte(from: b.xLower, below: b.xUpper)
                    let y = rng.nextWord(from: b.yLower, below: b.yUpper)
                    guard isClear(x: x, y: y, radius: radius, in: mask) else { continue }

                    var mate: (x: UInt8, y: UInt16)?
                    if command.placesPair {
                        // $2231: both positions must be clear before either is
                        // accepted, and the first is restored afterwards.
                        let p = partner(x: x, y: y, radius: radius,
                                        pairOffset: pairOffset)
                        guard isClear(x: p.x, y: p.y, radius: radius, in: mask)
                        else { continue }
                        mate = p
                    }

                    placed.append(Placement(x: x, y: y, radius: radius,
                                            partner: mate))
                    fill(x, y, radius, &mask)
                    break
                }
            }
        }
        return placed
    }

    /// Where a paired landmass's partner goes, relative to the first (`$223E`).
    ///
    /// The vertical offset is fixed at `2 * radius + radius / 8`; the horizontal
    /// one is **not** fixed — `pairOffset` is drawn at `$2186` from
    /// `$0ACB(radius * 5 / 7) + 1`, redrawn while it comes out as 1. Both
    /// positions must pass ``isClear`` before either is accepted.
    public static func partner(x: UInt8, y: UInt16, radius: UInt8,
                               pairOffset: UInt8) -> (x: UInt8, y: UInt16) {
        (x &- pairOffset, y &+ UInt16(radius) &* 2 &+ UInt16(radius) / 8)
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
