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
}
