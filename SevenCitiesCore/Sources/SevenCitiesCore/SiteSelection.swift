/// The two sites `$4500` picks once the first landmasses exist.
///
/// It runs from `$44EF`, in the middle of the land-mass command loop, right after
/// the mirror — and it is not land-mass work at all. It measures the mask's land
/// bands, picks a spot in one of them and, sometimes, a second spot far away in
/// the other, and files five zero-page bytes for each: column, row, a
/// north-of-`$D0` flag, and a kind that is either 9 or 7 — the second site always
/// gets the other of the pair (`$46B5 EOR #$0E`).
///
/// **What reads those bytes has not been established.** Two sites, far apart, one
/// of each of two kinds, placed on land wide enough to hold them: the shape fits
/// the game's two advanced civilizations, but that is a guess and the port does
/// not act on it. What is certain is that this has to be here, because it draws
/// seven times from the same generator the land-mass phase uses and its bounds
/// come from the mask. Skipping it puts every landmass after the first command in
/// the wrong place.
public enum SiteSelection {

    /// One chosen site — `$77`-`$7B`, and `$7C`-`$80` for the second.
    public struct Site: Sendable, Equatable {
        public let column: UInt8                     // $77 / $7C
        public let row: UInt16                       // $78:$79 / $7D:$7E
        /// `$7A` / `$7F`: clear for rows above `$D0`, `$FF` below.
        public let southern: Bool
        /// `$7B` / `$80`: 9 or 7, and the second site always takes the other.
        public let kind: UInt8
    }

    public struct Result: Sendable, Equatable {
        public let primary: Site
        public let secondary: Site?
        /// The original **always** ends up with a second site. When the two land
        /// bands are separate and a coin flip agrees it looks for one in the other
        /// band, which is `$4676`-`$46B9` and is ported. Every other time it takes
        /// `$46BC` instead — a systematic walk outward from the first site's row
        /// through the one band there is, reusing `$43E7` with `$4414` patched to
        /// `RTS`, and leaning on `$44B5`, `$44C3` and `$44D9`. That path is not
        /// ported, and this says so rather than letting a missing site read as a
        /// site the original did not place.
        public let secondaryUnported: Bool
    }

    /// `$451C`/`$4409`: the mask has no land where the scans need it, and the
    /// original abandons the whole phase.
    public struct Restart: Error, Sendable {}

    /// A band of rows containing land, as the scans at `$4503` find them.
    struct Band: Equatable {
        var start: UInt16                            // $2C:$2D / $30:$31
        var end: UInt16                              // $2E:$2F / $32:$33

        /// `$45E1`: the height, taken as a **byte**, so a band over 255 rows tall
        /// would wrap. Bands are clamped to `125...280` before this, so it cannot.
        var height: UInt8 {
            UInt8(truncatingIfNeeded: end) &- UInt8(truncatingIfNeeded: start)
        }

        /// `$458D` and `$45A1`: pull the band into `125...280`, but only where it
        /// already straddles the bound — a band wholly outside is left alone.
        mutating func clamp() {
            if start < 126 && end > 125 { start = (start & 0xFF00) | 125 }
            if end >= 256 && end & 0xFF > 0x18 && (start < 256 || start & 0xFF <= 0x18) {
                end = (end & 0xFF00) | 0x18
            }
        }
    }

    /// Chooses the sites (`$4503`-`$46B9`).
    public static func choose(in mask: LandMask,
                              rng: inout WorldMakerRNG) throws -> Result {
        var (first, second, separate) = try bands(in: mask)
        first.clamp()
        if separate { second.clamp() }

        // $45F3: use the first band unless it is under 40 rows and the second is
        // both usable and no worse. Either way only one band is drawn from, and
        // `$5D` survives only when the first band was tall enough on its own.
        var band = first
        var twoBands = separate
        if first.height < 0x28 && separate {
            if second.height >= 0x28 || second.height >= first.height { band = second }
            twoBands = false
        }

        // $462C: the first site.
        let drawn = try draw(in: band, mask: mask, rng: &rng)
        // $4646: the kind, on a coin flip, and the second site takes the other.
        let kind: UInt8 = Int8(bitPattern: rng.next()) < 0 ? 7 : 9
        let primary = site(drawn, kind: kind)

        // $4655: a second site only when the first band stood on its own, and
        // then only on a second coin flip.
        guard twoBands, Int8(bitPattern: rng.next()) < 0 else {
            return Result(primary: primary, secondary: nil, secondaryUnported: true)
        }

        // $4676: draw in the *other* band, then keep trying columns within the
        // land run that row crosses until one is far enough away.
        for _ in 0..<256 {
            let candidate = try draw(in: second, mask: mask, rng: &rng)
            for _ in 0..<256 {
                let column = rng.nextByte(from: candidate.run.left,
                                          below: candidate.run.right)
                if farApart(column: column, row: candidate.row, from: primary) {
                    return Result(primary: primary,
                                  secondary: site((column, candidate.row,
                                                   candidate.run),
                                                  kind: kind ^ 0x0E),
                                  secondaryUnported: false)
                }
            }
        }
        // $469B JMP $47B0: it gave up. The first site stands.
        return Result(primary: primary, secondary: nil, secondaryUnported: false)
    }

    /// Packages a drawn position with its kind (`$462F` and `$469E`).
    private static func site(_ drawn: (column: UInt8, row: UInt16,
                                       run: (left: UInt8, right: UInt8)),
                             kind: UInt8) -> Site {
        // $4637: the flag is set for rows at or past $00D0, and for every row
        // that needed a high byte at all.
        let southern = drawn.row >= 0xD0
        return Site(column: drawn.column, row: drawn.row, southern: southern,
                    kind: kind)
    }

    /// `$4479`: whether two sites are far enough apart.
    ///
    /// Squared distance against 11,968, and the arithmetic is the original's —
    /// each difference is reduced to a **byte** before being squared, with the
    /// sign taken from the full 16-bit subtraction. A pair 260 rows apart
    /// therefore measures as 4.
    static func farApart(column: UInt8, row: UInt16, from other: Site) -> Bool {
        var dy = UInt8(truncatingIfNeeded: row) &- UInt8(truncatingIfNeeded: other.row)
        if row < other.row { dy = (dy ^ 0xFF) &+ 1 }
        var dx = column &- other.column
        if column < other.column { dx = (dx ^ 0xFF) &+ 1 }

        let vertical = Arithmetic.multiply(dy, dy)
        let horizontal = Arithmetic.multiply(dx, dx)
        var low = UInt16(vertical.low) &+ UInt16(horizontal.low)
        let high = UInt16(vertical.high) &+ UInt16(horizontal.high) &+ (low > 0xFF ? 1 : 0)
        low &= 0xFF
        return (high << 8 | low) >= 0x2EE0
    }

    /// Draws a position inside a band (`$4373`).
    ///
    /// The row comes from two draws in the *opposite* order to `$247B`: the first
    /// supplies the high byte through its sign, the second the low byte — and the
    /// second is redrawn until it comes up **even**. A row outside the band, or on
    /// a land run under 30 cells wide, throws the whole thing away and starts over
    /// from the row.
    private static func draw(in band: Band, mask: LandMask,
                             rng: inout WorldMakerRNG)
        throws -> (column: UInt8, row: UInt16, run: (left: UInt8, right: UInt8)) {
        while true {
            // $439D: the sign of the first draw is the high byte.
            let high: UInt8 = rng.next() >= 0x80 ? 1 : 0
            var low: UInt8
            repeat { low = rng.next() } while low & 1 != 0     // $43D0 LSR / BCS
            let row = UInt16(high) << 8 | UInt16(low)
            guard row >= band.start && row < band.end else { continue }

            // $43EE: the first land in the row, then the first water past it.
            guard let run = landRun(row: row, in: mask) else { continue }
            guard run.right &- run.left >= 0x1E else { continue }

            // $4416: the carry is still set from the width test, so this is
            // `left + 9`, not `left + 8`.
            let column = rng.nextByte(from: run.left &+ 9, below: run.right &- 9)
            return (column, row, run)
        }
    }

    /// The first run of land in a row: its first cell, and the first water past it.
    private static func landRun(row: UInt16,
                                in mask: LandMask) -> (left: UInt8, right: UInt8)? {
        var column: UInt8 = 0
        while !mask.isLand(x: column, y: Int(row)) {
            column &+= 1
            if column == 0 { return nil }
        }
        let left = column
        while mask.isLand(x: column, y: Int(row)) {
            column &+= 1
            if column == 0 { return nil }
        }
        return (left, column)
    }

    /// The land bands (`$4503`-`$458B`).
    ///
    /// One scan runs down from row 110 for the first row with land and then on for
    /// the first row without; another runs up from row 300 and does the same. The
    /// two are separate landmasses when the first band ends above the second
    /// begins — which is what `$5D` records, and what decides whether a second
    /// site is even considered.
    static func bands(in mask: LandMask) throws -> (first: Band, second: Band,
                                                    separate: Bool) {
        func hasLand(_ row: UInt16) -> Bool {
            for column in 0...255 where mask.isLand(x: UInt8(column), y: Int(row)) {
                return true
            }
            return false
        }

        var row: UInt16 = 110                                   // $4503
        while !hasLand(row) {
            row += 1
            if row >= 300 { throw Restart() }                   // $451C JMP $2473
        }
        let firstStart = row
        while hasLand(row) {                                    // $4527
            row += 1
            if row >= 300 { break }
        }
        let firstEnd = row

        row = 300                                               // $4542
        while !hasLand(row) {                                   // $454A
            if row < 110 { break }
            row -= 1
            if row < 110 { break }
        }
        let secondEnd = row
        while hasLand(row) {                                    // $4563
            if row < 110 { break }
            row -= 1
            if row < 110 { break }
        }
        let secondStart = row

        return (Band(start: firstStart, end: firstEnd),
                Band(start: secondStart, end: secondEnd),
                firstEnd < secondStart)                         // $457E
    }
}
