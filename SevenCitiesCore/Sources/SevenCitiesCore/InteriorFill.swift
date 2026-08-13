/// The interior flood fill (`$194A`) — what turns a traced coastline into land.
///
/// The coastline walker draws a closed outline one cell thick and the span fill
/// closes the seam, but everything inside is still water. This fills it: a
/// scanline flood, seeded at the landmass centre, with an explicit stack rather
/// than recursion.
///
/// It is not reached by a call. `$1666` falls out of the span fill into
/// `$168D JMP $194A`, so the fill is the tail of the walk and its `RTS` is the
/// walk's — which is why `$23D3` returns only once the landmass is solid.
public enum InteriorFill {

    /// How a fill ended.
    public enum Outcome: Sendable, Equatable {
        /// The stack emptied — the interior is filled.
        case filled
        /// A scan ran off the mask buffer. The original's response is drastic:
        /// `$1906 JMP $2473` kills the raster interrupt and restarts the whole
        /// land-mass phase from `$20A3`, discarding every landmass placed so far.
        case restarted
    }

    /// A pushed scanline seed: the three bytes `$1929` files away, which are the
    /// column and the row pointer.
    private struct Seed {
        var column: UInt8
        var row: Int
    }

    /// `$1900`'s bounds check, which is on the **row pointer**, not the row.
    ///
    /// It compares the pointer's high byte against `$50` and `$91`, so the window
    /// is `$5000..<$9100` — a little below the mask's own base at `$5700`. Rows
    /// -56 to -1 therefore pass this guard and the original would write into the
    /// 1,792 bytes underneath. ``LandMask`` drops those writes instead of
    /// reproducing them; nothing observed has ever gone there, and the
    /// alternative is carrying a buffer for a region the map does not use.
    static func addressable(row: Int) -> Bool {
        let pointer = LandMask.base + row * LandMask.bytesPerRow
        return pointer >= 0x5000 && pointer < LandMask.ceiling
    }

    /// Fills a landmass interior from its centre (`$194A`).
    ///
    /// `column` and `row` are `$22` and `$23`/`$24` — the centre the placement
    /// loop chose, untouched by the walk.
    ///
    /// - Parameter plot: called for every cell the fill sets, in order.
    @discardableResult
    public static func fill(column centre: UInt8, row centreRow: Int,
                            in mask: inout LandMask,
                            plot: (UInt8, Int) -> Void = { _, _ in }) -> Outcome {
        // The stack lives at `$9100`, three bytes an entry, indexed by `$46` —
        // the same byte the walker used as its undo ring index, and the same
        // region, reused now that the walk is over. Slot 0 is never written:
        // `$1920` increments before it stores, and `$19AE` reads the slot it is
        // about to step below, so a pop at zero reads a slot that was never
        // filled and then ends the loop on the `$FF` wrap.
        var stack = [Seed](repeating: Seed(column: 0, row: 0), count: 256)
        var top: UInt8 = 0                                  // $46

        var column = centre                                 // $22
        var row = centreRow                                 // the row $29/$2A holds

        // $194E: walk left off any land under the centre. The centre of a fresh
        // landmass is water — the outline is a ring and nothing has filled it —
        // so in practice this does nothing at all, and it is here for the case
        // where a landmass overlaps one already drawn.
        while mask.isLand(x: column, y: row) { column &-= 1 }

        while true {
            // $1961: right to the first land, then back one onto the water beside
            // it. After a pop this re-finds the run's right edge, which may have
            // moved if another scanline filled part of it in the meantime.
            while !mask.isLand(x: column, y: row) { column &+= 1 }
            column &-= 1

            // $1976: fill leftward while the cells are water. Two ways out, and
            // the difference matters: hitting land leaves `$02` *on* the land
            // cell, while running down to column 0 leaves it at 0 having filled
            // that cell — the `DEC` at `$1989` happens before the test.
            let start = column                              // $51
            var scan = start                                // $02
            while true {
                if mask.isLand(x: scan, y: row) { break }
                mask.setLand(x: scan, y: row)
                plot(scan, row)
                scan &-= 1
                if scan == 0 { break }
            }
            let stop = scan                                 // $52

            // $1991: nothing filled means the seed was already land, so there is
            // nothing to seed from either.
            if stop != start {
                for neighbor in [row - 1, row + 1] {
                    guard addressable(row: neighbor) else { return .restarted }
                    pushRuns(from: start, downTo: stop, row: neighbor,
                             in: mask, stack: &stack, top: &top)
                }
            }

            // $19AE: pop. The counter is read, then stepped, then tested, so the
            // fill always makes one read past the bottom of the stack.
            let record = stack[Int(top)]
            let more = top != 0
            top &-= 1
            if !more { return .filled }
            column = record.column
            row = record.row
        }
    }

    /// Scans one row for water runs and pushes the start of each (`$1900`).
    ///
    /// Right to left across the span the fill just covered, pushing the **first**
    /// cell of every contiguous run of water — which, scanning this direction, is
    /// its rightmost cell, exactly where `$1961` expects to resume. `$0D` is the
    /// in-a-run flag, and it is a flag by sign: `DEC` from zero makes `$FF` and
    /// `INC` puts it back, with `BIT`/`BMI` reading bit 7.
    ///
    /// The span is half open. `$1941` decrements before comparing against `$52`,
    /// so the column the leftward fill stopped on is not scanned.
    private static func pushRuns(from start: UInt8, downTo stop: UInt8, row: Int,
                                 in mask: LandMask,
                                 stack: inout [Seed], top: inout UInt8) {
        var inRun = false                                   // $0D bit 7
        var column = start                                  // $22
        repeat {
            let land = mask.isLand(x: column, y: row)
            if inRun {
                if land { inRun = false }
            } else if !land {
                top &+= 1                                   // $1920 INC $46
                stack[Int(top)] = Seed(column: column, row: row)
                inRun = true
            }
            column &-= 1
        } while column != stop
    }
}
