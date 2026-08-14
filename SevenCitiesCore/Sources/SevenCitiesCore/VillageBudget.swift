/// How much room the map has for villages, counted before any are placed.
///
/// `$47DF` does not decide how many villages a band may have — it is told, out
/// of zero page, by work done two phases earlier. `$0C9B` unpacks the finished
/// mask into a 16-row by 16-column buffer at a time, `$1047` quarters each
/// buffer, and `$1060` counts the ground in a quarter. `$0D5D` then hands the
/// two totals to `$40FA`, which turns them into the budget and the draw the
/// village phase actually reads.
///
/// A port that starts at `$47DF` will go looking for that state and not find it.
public enum VillageBudget {

    /// `$1060`: whether one 8x8 quadrant has enough land to hold a village.
    ///
    /// It counts **column pairs**, not cells. The buffer holds two nibbles to a
    /// byte and `$1069 CMP #$0B / BCC` passes `$0B`, `$B0` and `$BB` while
    /// rejecting `$00` — so a byte with land in either half counts once, the
    /// score is out of thirty-two rather than sixty-four, and twenty means
    /// twenty pairs. Reading it as cells puts the threshold in the wrong place
    /// by a factor of two.
    static func eligible(row: Int, column: Int, in mask: LandMask) -> Bool {
        var pairs = 0
        for y in row..<(row + 8) {
            for pair in 0..<4 {
                let x = column + pair * 2
                if mask.isLand(x: UInt8(truncatingIfNeeded: x), y: y)
                    || mask.isLand(x: UInt8(truncatingIfNeeded: x + 1), y: y) {
                    pairs += 1
                }
            }
        }
        return pairs >= 0x14                                  // $1084
    }

    /// `$0C9B` and `$1047`: how many quadrants of each half of the map have the
    /// ground for a village.
    ///
    /// The map is walked as **four hundred sixteen-by-sixteen windows**, row
    /// major, each quartered into four 8x8 quadrants — sixteen hundred
    /// evaluations, which is exactly what the interpreter makes. A quadrant is
    /// counted against the northern total when its own top row is above 208 and
    /// the southern otherwise; that is `$1088`'s sixteen-bit compare against
    /// `$00D0`, and it is the *quadrant's* row rather than the window's.
    ///
    /// This was worked out from the counts rather than from the listing. The
    /// unpack shifts mask bytes out of its own instruction stream with
    /// `ASL abs,X` and fills a rolling buffer, which makes the geometry very
    /// hard to read and trivial to check: 400 windows, 1,600 evaluations, and
    /// 240 north against 246 south for seed `$1234` configuration 0.
    public static func eligibleQuadrants(in mask: LandMask)
        -> (north: Int, south: Int) {
        var north = 0, south = 0
        for windowRow in 0..<(LandMask.height / 16) {
            for windowColumn in 0..<(256 / 16) {
                for quadrant in 0..<4 {
                    let row = windowRow * 16 + (quadrant / 2) * 8
                    let column = windowColumn * 16 + (quadrant % 2) * 8
                    guard eligible(row: row, column: column, in: mask) else {
                        continue
                    }
                    if row < 0xD0 { north += 1 } else { south += 1 }
                }
            }
        }
        return (north, south)
    }

    // MARK: - `$40FA`

    /// What the village phase is handed, per band.
    public struct Budget: Sendable, Equatable {
        /// `$6C`/`$6D`: how many villages the band may have.
        public var villages: (north: UInt8, south: UInt8)
        /// `$6E`/`$6F`: the draw a quadrant has to beat before one is placed.
        /// Complemented at `$4173`, so a bigger number is an easier draw.
        public var threshold: (north: UInt8, south: UInt8)
        /// `$82`/`$83`, which always sum to twenty.
        public var spread: (north: UInt8, south: UInt8)

        public static func == (a: Budget, b: Budget) -> Bool {
            a.villages == b.villages && a.threshold == b.threshold
                && a.spread == b.spread
        }
    }

    /// `$0BEE` and `$0C0C`: divide, rounding to nearest.
    ///
    /// Both compare the remainder against **`divisor >> 1`** and carry when it
    /// reaches it, so the halfway case rounds up and an odd divisor rounds up a
    /// shade early. That is not a detail to smooth over: configuration 2's
    /// southern band divides 920 by 263 for a remainder of exactly 131 against a
    /// half of 131, and the difference between three and four there is the
    /// difference between a threshold of 51 and one of 0.
    static func rounded(_ dividend: Int, over divisor: Int) -> Int {
        guard divisor != 0 else { return 0 }
        let quotient = dividend / divisor
        return dividend % divisor >= divisor >> 1 ? quotient + 1 : quotient
    }

    /// Everything `$40FA` takes off the budgets, straight off a finished run.
    ///
    /// `$67`/`$68` are the second wave's island counts, and `$A8`/`$A9` are how
    /// many *small* landmasses went into each position table — `$1BD6`
    /// increments it whenever `$1B5F` files something with a radius under `$46`.
    /// Both are pre-mirror counts in the original, and both come out the same
    /// after it: the small landmasses are all placed by the second command,
    /// which runs once the mirror has already happened.
    public static func deductions(from run: LandMassStage.Run)
        -> (islands: (north: Int, south: Int),
            smallLandmasses: (north: Int, south: Int)) {
        func split<T>(_ items: [T], _ southern: (T) -> Bool) -> (Int, Int) {
            (items.filter { !southern($0) }.count,
             items.filter { southern($0) }.count)
        }
        let islands = split(run.islands) { $0.southern }
        let small = split(run.landmasses.filter { $0.radius < 0x46 }) {
            $0.southern
        }
        return (islands, small)
    }

    /// `$40FA`: turn the two quadrant counts into what `$47DF` reads.
    ///
    /// `$27` runs 1 then 0, so the southern band is worked out first and the
    /// northern second — which matters, because `$419C`'s cap and `$41BB`'s
    /// subtraction both treat them asymmetrically afterwards.
    public static func budget(north: Int, south: Int,
                              islands: (north: Int, south: Int),
                              smallLandmasses: (north: Int, south: Int))
        -> Budget {
        let total = north + south

        func band(_ eligible: Int) -> (villages: UInt8, threshold: UInt8,
                                       spread: UInt8) {
            // $410B: how many tenths of the map's eligible ground this band has.
            let tenths = rounded(eligible * 10, over: total)
            guard tenths != 0 else { return (0, 0xFF, 0) }    // $4122
            let clamped = min(tenths, 10)                     // $412C
            let product = clamped * 255                       // $4132
            let villages = rounded(product, over: 10)         // $413D

            let threshold: UInt8
            if villages >= eligible {
                // $4151: the band wants more villages than it has ground for,
                // and the draw becomes impossible to fail.
                threshold = 0
            } else {
                // $4155: the same product against the band's own count.
                let share = UInt8(truncatingIfNeeded: rounded(product,
                                                              over: eligible))
                let scaled = rounded(Int(share) * 255, over: 10)
                threshold = UInt8(truncatingIfNeeded: scaled) ^ 0xFF
            }
            return (UInt8(truncatingIfNeeded: villages), threshold,
                    UInt8(min(2 * clamped, 0x14)))            // $417B
        }

        let southern = band(south)                            // $27 = 1
        let northern = band(north)                            // $27 = 0

        // $419C: the two together may not exceed 255, and the larger gives way.
        var villages = (north: northern.villages, south: southern.villages)
        while Int(villages.north) + Int(villages.south) > 0xFF {
            if villages.north < villages.south || villages.north == 0 {
                villages.south &-= 1
            } else {
                villages.north &-= 1
            }
        }

        // $41BB: and the islands come off the top. A southern shortfall is
        // taken out of the northern band instead of being clamped away.
        let takeNorth = islands.north + smallLandmasses.north
        let takeSouth = islands.south + smallLandmasses.south
        villages.north = Int(villages.north) >= takeNorth
            ? villages.north &- UInt8(takeNorth) : 0
        if Int(villages.south) >= takeSouth {
            villages.south &-= UInt8(takeSouth)
        } else {
            villages.north &-= UInt8(truncatingIfNeeded:
                                        takeSouth - Int(villages.south))
            villages.south = 0
        }

        return Budget(villages: villages,
                      threshold: (northern.threshold, southern.threshold),
                      spread: (northern.spread, 0x14 &- northern.spread))
    }

    /// The budget a finished land-mass run implies, end to end.
    public static func budget(for run: LandMassStage.Run) -> Budget {
        let counted = eligibleQuadrants(in: run.mask)
        let take = deductions(from: run)
        return budget(north: counted.north, south: counted.south,
                      islands: take.islands,
                      smallLandmasses: take.smallLandmasses)
    }
}
