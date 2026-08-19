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
        /// The second site. `nil` only when both searches failed, which the
        /// original also allows — and which changes what `$47C6` does next.
        public let secondary: Site?
        /// `$EBCE`, the byte `$47B2` files away afterwards. Drawn from `$0B16`,
        /// and from a *different* distribution depending on whether a second site
        /// was found: centred on 1 with spread 1 when it was, on 2 with spread 6
        /// when it was not. Nothing in the land-mass phase reads it.
        public let parameter: UInt8
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

        // $4655: the other band is searched only when the first stood on its own
        // and a coin flip agrees. Note the flip is not made at all when `$5D` is
        // clear — `BEQ` jumps before `JSR $0AE2` — which Swift's `guard` gets right
        // only because it short-circuits left to right.
        var secondary: Site?
        if twoBands, Int8(bitPattern: rng.next()) < 0 {
            secondary = try acrossBands(primary: primary, band: second, kind: kind,
                                        mask: mask, rng: &rng)
        } else {
            secondary = try withinBand(primary: primary, band: band, kind: kind,
                                       mask: mask, rng: &rng)
        }

        // $47B2: a parameter drawn from one of two distributions, and on the
        // failing path the first site's kind is overwritten as well.
        if secondary != nil {
            let parameter = min(sample(base: 1, spread: 1, rng: &rng), 3)
            return Result(primary: primary, secondary: secondary, parameter: parameter)
        }
        let parameter = min(sample(base: 2, spread: 6, rng: &rng), 7)
        let settled = parameter >= 2
            ? Site(column: primary.column, row: primary.row,
                   southern: primary.southern, kind: 9)
            : primary
        return Result(primary: settled, secondary: nil, parameter: parameter)
    }

    /// The second site, looked for in the *other* land band (`$4676`-`$46B9`).
    private static func acrossBands(primary: Site, band: Band, kind: UInt8,
                                    mask: LandMask,
                                    rng: inout WorldMakerRNG) throws -> Site? {
        for _ in 0..<256 {
            let candidate = try draw(in: band, mask: mask, rng: &rng)
            for _ in 0..<256 {
                let column = rng.nextByte(from: candidate.run.left,
                                          below: candidate.run.right)
                if farApart(column: column, row: candidate.row, from: primary) {
                    return site((column, candidate.row, candidate.run),
                                kind: kind ^ 0x0E)
                }
            }
        }
        return nil                                       // $469B JMP $47B0
    }

    /// The second site, looked for in the same band as the first (`$46BC`).
    ///
    /// Where the other search samples, this one *walks*. It starts at the far end
    /// of whichever half of the band is longer, rounded up to an even row, and
    /// steps two rows at a time back toward the first site until it finds a row
    /// whose first land run is at least 30 cells wide. Then it draws columns in
    /// that run until one is far enough away — and then keeps walking, still two
    /// rows at a time, for as long as that column stays far enough. The two rows
    /// that bracket, one from each end of that walk, become the range a final row
    /// is drawn from. If the column turns out to be water in the drawn row, it
    /// falls back to the row it started the walk from.
    ///
    /// The original does all of this by patching `$4373` in two places: `$4414`
    /// becomes `RTS` so `$43E7` can be called for the row scan alone, and later
    /// `$43E7` becomes `RTS` so `$4373` is left as the row draw alone.
    private static func withinBand(primary: Site, band: Band, kind: UInt8,
                                   mask: LandMask,
                                   rng: inout WorldMakerRNG) throws -> Site? {
        // $46C0: the halves are measured as **bytes**, from the low bytes alone.
        let below = UInt8(truncatingIfNeeded: primary.row)
            &- UInt8(truncatingIfNeeded: band.start)
        let above = UInt8(truncatingIfNeeded: band.end)
            &- UInt8(truncatingIfNeeded: primary.row)

        var row: UInt16
        if above >= below {
            row = primary.row &+ UInt16(above)
        } else {
            row = primary.row &- UInt16(below)           // $46D8, two's complement
        }
        if row & 1 != 0 { row &+= 1 }                    // $46EF: round up to even

        // $46FA: which way the walk runs. `$13` is set when the start is past the
        // first site, so the steps subtract.
        let stepsBack = primary.row < row

        /// `$44C3` / `$44D9`: two rows toward the first site, and whether the band
        /// still contains the result.
        func step(_ row: inout UInt16) -> Bool {
            if stepsBack {
                row &-= 2
                return row >= band.start
            }
            row &+= 2
            return row < band.end
        }

        var counter: UInt8 = 0                           // $52, and it never resets
        while true {
            // $470E: `$43E7` with `$4414` patched to `RTS` — the row scan alone.
            if let run = landRun(row: row, in: mask),
               run.right &- run.left >= 0x1E {
                // $4726: columns, until one is far enough or 256 have failed.
                var column: UInt8?
                while true {
                    let candidate = rng.nextByte(from: run.left &+ 9,
                                                 below: run.right &- 9)
                    if farApart(column: candidate, row: row, from: primary) {
                        column = candidate
                        break
                    }
                    counter &+= 1                        // $47A6
                    if counter == 0 { break }            // $47AD JMP $4713
                }
                if let column {
                    return try settle(column: column, from: row, primary: primary,
                                      kind: kind, stepsBack: stepsBack, band: band,
                                      mask: mask, rng: &rng)
                }
            }
            // $4713: step, and give up at the edge of the band.
            guard step(&row) else { return nil }         // $471C JMP $47B0
        }
    }

    /// Walks the found row as close to the first site as it can and settles on one
    /// in between (`$4737`-`$47A3`).
    private static func settle(column: UInt8, from anchor: UInt16, primary: Site,
                               kind: UInt8, stepsBack: Bool, band: Band,
                               mask: LandMask,
                               rng: inout WorldMakerRNG) throws -> Site {
        var row = anchor                                 // $16/$17 keeps the anchor
        while true {                                     // $473F
            if stepsBack {
                row &-= 2
                if row < band.start { break }
            } else {
                row &+= 2
                if row >= band.end { break }
            }
            if !farApart(column: column, row: row, from: primary) { break }
        }

        // $4754: the walk's two ends bound the draw, in whichever order the
        // direction put them.
        let bounds = stepsBack ? Band(start: row, end: anchor)
                               : Band(start: anchor, end: row)
        // $4782: `$43E7` patched to `RTS` leaves `$4373` as its row draw alone.
        let drawn = drawRow(in: bounds, rng: &rng)
        // $478A: keep it only if the column is land in that row.
        let settled = mask.isLand(x: column, y: Int(drawn)) ? drawn : anchor
        return Site(column: column, row: settled, southern: settled >= 0xD0,
                    kind: kind ^ 0x0E)
    }

    /// Twelve draws summed, centred and scaled (`$0B16`).
    ///
    /// The only non-flat generator found anywhere in the World Maker: sum twelve
    /// bytes, subtract 1,536, halve it as a *signed* value, scale by the spread and
    /// keep the high byte. A negative result comes out as zero (`$0B7E BPL`), so
    /// the distribution is a clipped normal around `base`.
    static func sample(base: UInt8, spread: UInt8,
                       rng: inout WorldMakerRNG) -> UInt8 {
        guard spread != 0 else { return base }           // $0B18
        var sum: UInt16 = 0
        for _ in 0..<12 { sum = sum &+ UInt16(rng.next()) }
        var centred = sum &- 0x0600                      // $0B5D
        centred = UInt16(bitPattern: Int16(bitPattern: centred) >> 1)  // $0B6A
        // $0B83 is a 17-round shift-add multiply; only its low word is used, which
        // makes it a plain wrapping product.
        let product = centred &* UInt16(spread)
        let rounding: UInt8 = UInt8(truncatingIfNeeded: product) >= 0x80 ? 1 : 0
        let result = base &+ UInt8(truncatingIfNeeded: product >> 8) &+ rounding
        return result & 0x80 != 0 ? 0 : result           // $0B7E
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

    /// `$4373`'s row draw, without the land scan that normally follows it.
    ///
    /// Two draws in the *opposite* order to `$247B`: the first supplies the high
    /// byte through its sign, the second the low byte, redrawn until it comes up
    /// even. Out of band, both are thrown away.
    ///
    /// The draw only ever produces an even row below 512, so a band holding none
    /// of those is a redraw with no answer — an **inverted** band above all,
    /// which `settle` hands it whenever its walk wraps past the band's start.
    /// That is a hang in the original. See ``WorldMakerRNG/limit``.
    static func drawRow(in band: Band, rng: inout WorldMakerRNG) -> UInt16 {
        // Only even rows below 512 can come out of it, so the band holds at most
        // 256 answers. A thousand throws is four times over having tried them
        // all; past that the band holds none and the caller's own bound takes
        // over.
        var tries = 0
        while !rng.isStuck {
            tries += 1
            if tries > 1024 { return band.start }
            let high: UInt8 = rng.next() >= 0x80 ? 1 : 0         // $439D
            var low: UInt8
            repeat { low = rng.next() } while low & 1 != 0 && !rng.isStuck
            let row = UInt16(high) << 8 | UInt16(low)
            if row >= band.start && row < band.end { return row }
        }
        return band.start
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
        // A band with no row wide enough to hold a site is a redraw with no
        // answer, and `$4373` has no bound on it — the fourth of the World
        // Maker's hangs. The row space is at most 256 even rows, so a thousand
        // throws means no row in this band will ever carry a thirty-cell run of
        // land.
        //
        // `$2473` is the recovery the original already has for a phase that
        // cannot continue, and it is the honest one here: the *mask* is what is
        // unusable, so the land-mass phase runs again and builds a different one.
        // Skipping the site is not an option — `$462C` needs the primary.
        var attempts = 0
        while !rng.isStuck {
            attempts += 1
            if attempts > 1024 { throw Restart() }
            let row = drawRow(in: band, rng: &rng)

            // $43EE: the first land in the row, then the first water past it.
            guard let run = landRun(row: row, in: mask) else { continue }
            guard run.right &- run.left >= 0x1E else { continue }

            // $4416: the carry is still set from the width test, so this is
            // `left + 9`, not `left + 8`.
            let column = rng.nextByte(from: run.left &+ 9, below: run.right &- 9)
            return (column, row, run)
        }
        throw WorldMakerRNG.Stuck(draws: rng.draws)
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
