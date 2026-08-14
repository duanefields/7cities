/// The coastline walker — how the World Maker gives a landmass its shape.
///
/// A landmass is not drawn as a blob. It is built in three steps: the outline is
/// **traced** as a perturbed circle, one quadrant at a time; the columns are then
/// **span filled**; and finally the interior is **flood filled**. This type holds
/// the first of those, plus the geometry all three share.
///
/// Transcribed from `$15AD` and its neighbors in `game3`. See NOTES.md — in
/// particular, the traced behavior there corrects three readings that looked
/// right from the disassembly alone and were not.
public enum CoastlineWalker {

    /// Where the walk is, relative to the landmass center.
    ///
    /// **The center never moves during a fill.** `$22`/`$23:$24` hold the
    /// coordinate the placement loop chose and keep it; `$14`/`$15` are offsets
    /// from it and are what the walk advances. A port that moves an absolute
    /// position is wrong however faithfully its routines are transcribed.
    public struct Offset: Sendable, Equatable {
        public var dx: UInt8
        public var dy: UInt8
        public init(dx: UInt8, dy: UInt8) {
            self.dx = dx
            self.dy = dy
        }
    }

    /// Resolves an offset to an absolute cell (`$13E0`).
    ///
    /// The heading selects a quadrant by negating one or both components, and
    /// the pattern is **not** the symmetric one you would guess:
    ///
    /// | heading | dx | dy |
    /// | :------ | :- | :- |
    /// | 0       | -  | -  |
    /// | 1       | -  | +  |
    /// | 2       | +  | +  |
    /// | 3       | +  | -  |
    ///
    /// `dx` negates for headings 0 and 1 (`CPX #$02 / BCS`), `dy` for 0 and 3
    /// (`BEQ` / `CMP #$03 / BNE`). Verified against cells the original itself
    /// computed, read out of its registers just past the call.
    ///
    /// The arithmetic is deliberately modular: x is a byte and wraps, y is
    /// sixteen bits and wraps, exactly as the 6502 does it. A landmass near an
    /// edge relies on that wrap.
    @inlinable
    public static func cell(offset: Offset, heading: UInt8,
                            centerX: UInt8, centerY: UInt16) -> (x: UInt8, y: Int) {
        // $13EC: EOR #$FF / ADC #$01 with carry known clear from the CPX.
        var horizontal = offset.dx
        if heading < 2 { horizontal = (horizontal ^ 0xFF) &+ 1 }
        let x = horizontal &+ centerX

        // $13FC: a 16-bit negate of dy, which was widened at $13E0 with a zero
        // high byte, then added to the center.
        var vertical = UInt16(offset.dy)
        if heading == 0 || heading == 3 { vertical = (~vertical) &+ 1 }
        let y = centerY &+ vertical

        return (x, Int(y))
    }
}

// MARK: - The per-step advance

extension CoastlineWalker {

    /// Advances one axis by one cell, or declines to (`$1555` and `$1583`).
    ///
    /// These are the walk's only consumers of randomness, so they set the whole
    /// sequence — and they consume a *variable* number of draws, because the
    /// retry at `$1564` redraws while a value comes up `$FF`. Measured over one
    /// continent, calls took one draw 1,106 times, two 299 times and three once.
    /// A port that lands on the right coordinate having burned a different
    /// number of draws desynchronizes everything after it.
    ///
    /// The threshold decides: a draw at or above ``WalkerState/threshold``
    /// advances, below it the step is declined. Since `$18` grows with the
    /// coordinate, an axis becomes progressively less willing to move — which is
    /// what curves the walk.
    ///
    /// The direction comes from the signed table at `$13DA` (`01 FF 00 00 FF
    /// 01`) indexed by `heading & 1`, and `EOR #$FE` flips it, turning `$01`
    /// into `$FF` and back. One table serves both directions.
    ///
    /// - Returns: whether the coordinate moved.
    @discardableResult
    static func advance(_ state: inout WalkerState, axis: Axis) -> Bool {
        // $1555 / $1583: draw, then compare against the threshold.
        let draw = state.rng.next()
        var flip: UInt8 = 0

        if draw < state.threshold {
            // $1560 / $158E: the bias path is only taken when `$19` disagrees
            // with the routine, and the caller always picks the matching one,
            // so in the walk this simply declines the step. Transcribed as the
            // original branches rather than simplified away, because a future
            // caller could pick differently.
            let disagrees = (axis == .x) ? (state.axis != 0) : (state.axis == 0)
            guard disagrees else { return false }

            // **Only the horizontal stepper redraws.** `$1564` loops while the
            // value comes up `$FF`; `$1592` takes whatever it gets. The two
            // routines are otherwise the same shape, which is exactly why the
            // port had the retry on both — and it stays invisible until a turn
            // clears the biases and opens this path at all.
            var retry = state.rng.next()
            if axis == .x {
                while retry == 0xFF { retry = state.rng.next() }
            }
            let bias = (axis == .x) ? state.biasX : state.biasY
            if retry < bias { return false }
            flip = 0xFE
        }

        // $1573 / $159D: signed step, sign flipped when `flip` is $FE.
        //
        // The two steppers index *different* tables. `$1555` reads `$13DA`
        // (`01 FF`), `$1583` reads `$13DE` (`FF 01`) — the same pair reversed,
        // four bytes further along. Using one for both would mirror every
        // vertical step.
        let table = (axis == .x) ? signedStep : signedStepVertical
        let delta = table[Int(state.heading & 1)] ^ flip
        switch axis {
        case .x: state.stepped.dx = state.stepped.dx &+ delta
        case .y: state.stepped.dy = state.stepped.dy &+ delta
        }
        return true
    }

    /// Which coordinate a step advances.
    enum Axis { case x, y }

    /// `$13DA`, the signed direction table: `+1` and `-1`, indexed by
    /// `heading & 1`. `$1583` reads it four bytes further along at `$13DE`,
    /// which is the same pair in the opposite order.
    static let signedStep: [UInt8] = [0x01, 0xFF]
    static let signedStepVertical: [UInt8] = [0xFF, 0x01]
}

// MARK: - Shape parameters

extension CoastlineWalker {

    /// Recomputes the shape parameters from the radii (`$1731`).
    ///
    /// Note which radius each one uses: `span` and `third` come from the
    /// command's nominal ``WalkerState/radius``, while `target`, `shape` and
    /// `inverseSlack` come from the *working* radius, which `$178A` modulates as
    /// the walk proceeds. Mixing them up changes the coastline's character
    /// without changing anything obviously.
    ///
    /// `inverseSlack` divides by `target - workingRadius`, which is **zero** for
    /// a radius-3 satellite. The original's divide returns `$FF` there rather
    /// than faulting, and the port inherits that through ``Arithmetic``.
    static func recomputeShape(_ s: inout WalkerState) {
        // $1731: $0F = radius * 5 / 7, then $10 = $80 / $0F.
        let five = Arithmetic.multiply(s.radius, 5)
        s.span = Arithmetic.divide(high: five.high, low: five.low, by: 7).quotient
        s.inverseSpan = Arithmetic.divide(high: 0, low: 0x80, by: s.span).quotient
        // $13 = radius * 3 / 8.
        let three = Arithmetic.multiply(s.radius, 3)
        s.third = Arithmetic.divide(high: three.high, low: three.low, by: 8).quotient
        // $12 = $25 = (working/5 + working)^2 / working.
        let fifth = Arithmetic.divide(high: 0, low: s.workingRadius, by: 5).quotient
        let scaled = fifth &+ s.workingRadius
        let square = Arithmetic.multiply(scaled, scaled)
        s.target = Arithmetic.divide(high: square.high, low: square.low,
                                     by: s.workingRadius).quotient
        s.shape = s.target
        // $11 = $80 / ($12 - working).
        s.inverseSlack = Arithmetic.divide(high: 0, low: 0x80,
                                           by: s.target &- s.workingRadius).quotient
    }

    /// Modulates the working radius from the walk's vertical position
    /// (`$178A`), then recomputes the shape.
    ///
    /// **Continents only.** `$17A8` returns immediately when the nominal radius
    /// is below `$46`, so islands and satellites keep a constant working radius
    /// — which is exactly what the traces show, `$21` fixed at 10 and 3 while a
    /// continent's climbs 70, 71, 72, 73, 74.
    static func modulateRadius(_ s: inout WalkerState) {
        guard s.radius >= 0x46 else { return }
        let half = s.offset.dy >> 1
        var value = s.drift &+ half
        if value & 0x80 != 0 { value = (value ^ 0xFF) &+ 1 }   // absolute value
        s.workingRadius = value
        recomputeShape(&s)
    }

    /// Flips the drift that biases the working radius (`$17A6`).
    ///
    /// Continents only again, and only on three draws in four (`AND #$03`,
    /// returning when the result is zero). The drift alternates between
    /// `radius / 2` and `-(radius / 2 + radius)` depending on its own sign, so
    /// the coastline bulges and pinches along its length.
    static func adjustDrift(_ s: inout WalkerState) {
        guard s.radius >= 0x46 else { return }
        guard s.rng.next() & 0x03 != 0 else { return }
        var value = s.radius >> 1
        if s.drift & 0x80 == 0 {
            value = ((value &+ s.radius) ^ 0xFF) &+ 1
        }
        s.drift = value
    }
}

// MARK: - Candidate validation

extension CoastlineWalker {

    /// How far the current offset is from the centre, over the working radius
    /// (`$19CC`).
    ///
    /// `(dx * dx + dy * dy) / workingRadius` — a distance metric, not a true
    /// radius, and the division is the original's, warts included. The result
    /// lands in both the accumulator and `$03`, which is why `$255D` can read
    /// `$03` immediately afterwards as the metric.
    static func distanceMetric(_ s: WalkerState) -> UInt8 {
        let dx = Arithmetic.multiply(s.offset.dx, s.offset.dx)
        let dy = Arithmetic.multiply(s.offset.dy, s.offset.dy)
        var low = UInt16(dx.low) &+ UInt16(dy.low)
        let high = UInt16(dx.high) &+ UInt16(dy.high) &+ (low > 0xFF ? 1 : 0)
        low &= 0xFF
        return Arithmetic.divide(high: UInt8(truncatingIfNeeded: high),
                                 low: UInt8(low), by: s.workingRadius).quotient
    }

    /// Whether the offset sits on the coastline circle, within a tolerance of
    /// three (`$19EE`).
    ///
    /// Modulates the radius first, so the circle it is tested against is the one
    /// this step is aiming at rather than the one the last step used.
    static func isOnCircle(_ s: inout WalkerState) -> Bool {
        modulateRadius(&s)
        let metric = distanceMetric(s)
        var difference = metric &- s.workingRadius
        if metric < s.workingRadius { difference = (difference ^ 0xFF) &+ 1 }
        return difference < 3
    }

    /// The full candidate test (`$1A00`): on the circle, and with clear water
    /// either side.
    ///
    /// The horizontal scans are asymmetric and easy to get wrong. To the left it
    /// runs from `max(column - 10, 1)` up to but not including the column; to the
    /// right from `column + 1` through `column + 10`. The left scan is skipped
    /// entirely when the column is 1 (`CPX #$01 / BEQ`), and its start clamps to
    /// 1 rather than 0.
    static func isCandidateClear(_ s: inout WalkerState, in mask: LandMask) -> Bool {
        guard isOnCircle(&s) else { return false }

        let (column, row) = cell(offset: s.offset, heading: s.heading,
                                 centerX: s.centerX, centerY: s.centerY)
        if column != 1 {
            var probe = column >= 10 ? column &- 10 : 1
            while probe < column {
                if mask.isLand(x: probe, y: row) { return false }
                probe &+= 1
            }
        }
        var probe = column &+ 1
        let limit = column &+ 11
        while probe < limit {
            if mask.isLand(x: probe, y: row) { return false }
            probe &+= 1
        }
        return true
    }
}

// MARK: - The step evaluator

extension CoastlineWalker {

    /// `$13DA`, read as a signed table of nine direction pairs.
    ///
    /// The bytes are `01 FF 00 00 FF 01`, and `$1476` indexes them twice — once
    /// at `2 * (direction mod 3) + horizontalBase` for x, once at
    /// `2 * (direction div 3) + verticalBase` for y. So `direction` 0...8
    /// enumerates a 3x3 neighborhood of `+1`, `0`, `-1` on each axis, with the
    /// bases rotating it into the current quadrant.
    static let directionTable: [UInt8] = [0x01, 0xFF, 0x00, 0x00, 0xFF, 0x01]

    /// Proposes the candidate for one of the nine directions (`$1476`).
    ///
    /// Writes ``WalkerState/candidate`` and reports whether it is worth testing
    /// at all. The early refusal at `$14AA` only applies when `$0E` is set and
    /// the heading is even, and rejects candidates whose x has fallen below 2 —
    /// keeping the walk off the left edge.
    static func propose(_ s: inout WalkerState, direction: UInt8,
                        horizontalBase: UInt8, verticalBase: UInt8,
                        edgeGuard: Bool) -> Bool {
        // $1476: direction mod 3, by repeated subtraction as the original does.
        var horizontal = direction
        if horizontal >= 3 { horizontal &-= 3 }
        if horizontal >= 3 { horizontal &-= 3 }
        let xIndex = Int((horizontal << 1) &+ horizontalBase)
        s.candidate.dx = directionTable[xIndex] &+ s.offset.dx

        // $1491: direction div 3, counted rather than divided.
        var vertical: UInt8 = 0
        if direction >= 3 { vertical += 1 }
        if direction >= 6 { vertical += 1 }
        let yIndex = Int((vertical << 1) &+ verticalBase)
        s.candidate.dy = directionTable[yIndex] &+ s.offset.dy

        // $14AA: refuse near the left edge, even headings only.
        if edgeGuard && s.heading & 1 == 0 && s.candidate.dx < 2 { return false }
        return true
    }

    /// Where the 3x3 scan starts, given a resolved candidate cell (`$14C0`).
    ///
    /// The original decrements both the column and the row *before* `$141C`
    /// builds the row pointer, so the block runs down and right from one cell
    /// up and left of the candidate — it surrounds the candidate rather than
    /// being anchored on it.
    static func scanOrigin(column: UInt8, row: Int) -> (column: UInt8, row: Int) {
        (column &- 1, row - 1)
    }

    /// Counts land in a 3x3 block (`$14E0`).
    ///
    /// Nine cells accumulated into the counters at `$35`, three across then a
    /// row down via `$289D`, three times. Takes the origin rather than deriving
    /// it so the counting and the origin arithmetic can fail separately.
    static func neighborCount(fromColumn column: UInt8, row: Int,
                              in mask: LandMask) -> Int {
        var count = 0
        for dy in 0..<3 {
            for dx in 0..<3 where mask.isLand(x: column &+ UInt8(dx), y: row + dy) {
                count += 1
            }
        }
        return count
    }
}

// MARK: - The walk

extension CoastlineWalker {

    /// One entry in the undo ring at `$9100` (`$15CA`).
    ///
    /// Twelve bytes: the nine tried-direction flags from `$2C`-`$34`, then the
    /// offset and heading. The flags are the reason the ring exists — restoring
    /// them resumes the direction search where it left off, so an unwind does
    /// not re-try directions already known to fail.
    ///
    /// It does **not** hold the generator. Backtracking rewinds position, not
    /// randomness.
    public struct UndoRecord: Sendable {
        public var tried: [UInt8]        // $2C-$34
        public var offset: Offset        // $14/$15
        public var heading: UInt8        // $1A
    }

    /// The ring's capacity (`$15BD`: `CMP #$C9`).
    public static let ringCapacity = 201

    /// Chooses the axis and threshold, then advances one coordinate (`$24FD`).
    ///
    /// Both axes move each iteration, and the order matters. The **smaller**
    /// coordinate goes first — ties broken by a coin flip at `$252D` — with a
    /// threshold scaled from its own value, so an axis that has run ahead
    /// becomes reluctant. The other follows with a threshold derived from the
    /// radius error, which is what pulls the walk back onto the circle.
    static func proposeStep(_ s: inout WalkerState) {
        // $2520: the smaller coordinate steps first.
        if s.offset.dx < s.offset.dy {
            s.axis = 0
        } else if s.offset.dx > s.offset.dy {
            s.axis = 1
        } else {
            s.axis = s.rng.next() & 0x80 != 0 ? 1 : 0
        }

        // $2534: threshold from the chosen coordinate, clamped on overflow.
        let coordinate = s.axis == 0 ? s.offset.dx : s.offset.dy
        let scaled = Arithmetic.multiply(coordinate, s.inverseSpan)
        s.threshold = scaled.high != 0 ? 0xFF : scaled.low

        s.stepped = s.offset
        advance(&s, axis: s.axis == 0 ? .x : .y)

        // $2559: threshold from the radius error for the second axis.
        let metric = distanceMetric(s)
        if s.target < metric {
            s.threshold = 0
        } else {
            let slack = s.target &- metric
            if slack == 0 {
                s.threshold = 0xFF
            } else {
                let product = Arithmetic.multiply(slack, s.inverseSlack)
                s.threshold = product.high != 0 ? 0xFF : product.low
            }
        }

        // $2578: the threshold is inverted for two of the four quadrants.
        if s.axis != 0 {
            if s.heading != 1 && s.heading != 3 { s.threshold ^= 0xFF }
            advance(&s, axis: .x)
        } else {
            if s.heading != 0 && s.heading != 2 { s.threshold ^= 0xFF }
            advance(&s, axis: .y)
        }
    }

    /// Turns the stepper's movement into one of the nine direction indices
    /// (`$25B9`).
    ///
    /// Index 4 is "no movement", and the mapping is deliberately arithmetic
    /// rather than a lookup: the x delta shifts the index by one and the y delta
    /// by three, each sign-flipped when its base is zero.
    static func directionIndex(_ s: WalkerState,
                               horizontalBase: UInt8, verticalBase: UInt8) -> UInt8 {
        var index: UInt8 = 4
        var dx = s.stepped.dx &- s.offset.dx
        if dx != 0 {
            if horizontalBase == 0 { dx ^= 0xFE }
            index = index &+ dx
        }
        var dy = s.stepped.dy &- s.offset.dy
        if dy != 0 {
            if verticalBase == 0 { dy ^= 0xFE }
            for _ in 0..<3 { index = index &+ dy }
        }
        return index
    }
}

// MARK: - The outline trace

extension CoastlineWalker {

    /// What ended a fill's outline trace.
    public enum Outcome: Sendable, Equatable {
        /// The heading reached 4 — the circle closed normally.
        case closed
        /// The walk exhausted the undo ring without finding a way forward.
        case exhausted
    }

    /// Traces one landmass outline (`$23D3` into `$15AD`).
    ///
    /// The shape of the loop, which is not obvious from any single routine:
    ///
    /// 1. `$24FD` proposes — both axes step, and the movement maps to one of
    ///    nine directions.
    /// 2. `$2603` evaluates that direction with `$1476`; on refusal it tries
    ///    random untried ones, and after nine failures backtracks.
    /// 3. `$15AD` commits — write the undo record, adopt the candidate, plot.
    /// 4. When the axis coordinate for the current heading reaches zero, turn.
    ///    Four turns close the circle.
    ///
    /// `plot` is called for every cell the walk commits, in order, which is what
    /// the reference traces record.
    public static func traceOutline(
        _ s: inout WalkerState, in mask: inout LandMask,
        plot: (UInt8, Int) -> Void = { _, _ in },
        erase: (UInt8, Int) -> Void = { _, _ in }
    ) -> Outcome {
        var ring = [UndoRecord?](repeating: nil, count: ringCapacity)
        var tried = [UInt8](repeating: 0, count: 9)
        var edgeFlag = false
        // `$2B`, set to `$FF` at $23EA and cleared only when the ring wraps.
        var ringWrapped = false

        // $23D3: the candidate starts directly "above" the centre.
        s.candidate = Offset(dx: 0, dy: s.radius)
        s.heading = 0
        s.step = 0xFF

        var guardCount = 0
        outline: while guardCount < 200_000 {
            guardCount += 1

            // $15AD: the edge flag latches once the candidate reaches x == 2.
            if !edgeFlag && s.candidate.dx == 2 { edgeFlag = true }

            // $15B9: advance the ring slot, wrapping at 201.
            s.step = s.step &+ 1
            if s.step >= UInt8(ringCapacity) {
                s.step = 0
                ringWrapped = true                          // $15C5 STA $2B
            }
            ring[Int(s.step)] = UndoRecord(tried: tried, offset: s.offset,
                                           heading: s.heading)

            // $15E2: adopt the candidate and draw it.
            s.offset = s.candidate
            let (column, row) = cell(offset: s.offset, heading: s.heading,
                                     centerX: s.centerX, centerY: s.centerY)
            mask.setLand(x: column, y: row)
            plot(column, row)

            // $15ED: the partner's walk climbing back above the switch row is
            // what ends it. `$15FD` is called for its side effect only — the
            // comparison at `$1600` is thrown away by the very next `LDA` — but it
            // modulates the working radius, so it has to happen.
            // `$186C` finishes with `JMP $24FD`, which is the proposal — not the
            // top of the loop — so the turn and the closure are both skipped on
            // the way through.
            var switched = false
            if s.mode && s.heading == 3 {
                if s.offset.dx < s.span { _ = isOnCircle(&s) }
                if row < Int(s.switchRow) {
                    switchBack(&s, row: row, column: column, in: &mask, plot: plot)
                    ringWrapped = false                 // $1880 STX $2B
                    switched = true
                }
            }

            // $160F: turn when the heading's axis coordinate reaches zero.
            let axisValue = s.heading & 1 == 1 ? s.offset.dx : s.offset.dy
            if !switched && axisValue == 0 {
                // $1622: a draw whose result is thrown away. `CMP #$00` can only
                // set the carry, so the `LDX #$FF` at `$162B` is unreachable and
                // both biases are always cleared. The draw still has to happen —
                // it is the generator that matters here, not the value.
                if s.radius >= 0x46 {
                    _ = s.rng.next()
                    s.biasX = 0
                    s.biasY = 0
                }
                s.heading &+= 1
                adjustDrift(&s)
                if s.heading == 2 { edgeFlag = false }
                if s.heading == 4 {
                    s.heading = 3
                    spanFill(&s, in: &mask, plot: plot)
                    return .closed
                }
            }

            // $1690: the closure. Reached whether or not a turn just happened,
            // and it fires on **`dx` below 2**, not on `dx` reaching zero — so
            // the last quadrant ends as soon as the walk comes near the vertical
            // axis rather than landing exactly on it. Missing this leaves the
            // walk running past the point the original stopped.
            if !switched && s.heading == 3 && s.offset.dx < 2 {
                // $169C: directions 3, 6 and 0 in turn, with bases (1, 0). The
                // third is tried for its side effect even when it refuses — the
                // candidate it leaves behind is plotted regardless.
                for closing: UInt8 in [3, 6, 0] {
                    let usable = propose(&s, direction: closing, horizontalBase: 1,
                                         verticalBase: 0, edgeGuard: edgeFlag)
                        && accepts(&s, in: mask)
                    if usable { break }
                }
                // $16AF: the candidate is plotted, and **not adopted**. It is
                // passed to `$1728` in the registers; `$14`/`$15` are left alone,
                // so the span fill that follows starts from where the walk
                // actually stands rather than from the cell just drawn. Adopting
                // it here costs one extra cell in the seam whenever the two
                // differ.
                let (column, row) = cell(offset: s.candidate, heading: s.heading,
                                         centerX: s.centerX, centerY: s.centerY)
                mask.setLand(x: column, y: row)
                plot(column, row)
                spanFill(&s, in: &mask, plot: plot)
                return .closed
            }

            // $24FD: propose, then search the nine directions for one that works.
            //
            // **A proposal that moves nothing re-proposes; it does not commit.**
            // `$25E6` compares the direction index against 4 — the centre of the
            // 3x3, meaning neither axis advanced — and `JMP $24FD` runs the
            // generator again *without* plotting. Treating that as a normal
            // iteration duplicates the cell, which is exactly how the island
            // diverged at plot 9: the original spent two iterations standing
            // still at (8,7) before moving to (9,7).
            proposal: while true {
                let horizontalBase = s.heading >> 1
                let verticalBase: UInt8 = (s.heading == 0 || s.heading == 3) ? 0 : 1
                // $2507: the slot this search started from, for the ring-full
                // guard at $16EC.
                let startSlot = s.step &+ 1

                var direction: UInt8 = 4
                var stalls = 0
                while direction == 4 && stalls < 10_000 {
                    // $24FD proper, and every way back into it comes through
                    // here: the radius is modulated first, and only then does the
                    // isthmus test get its look at `dx`.
                    modulateRadius(&s)

                    // $2509: still on the first continent, the command is paired,
                    // and the second quadrant has brought `dx` back **below** the
                    // pair offset — `$2519 BCS` skips the jump, so it is the small
                    // side of the comparison that fires. `$50` is set inside
                    // `buildIsthmus`, which is what stops it firing again.
                    if !s.mode && s.paired && s.heading == 1
                        && s.offset.dx < s.pairOffset {
                        buildIsthmus(&s, in: &mask, plot: plot)
                        ringWrapped = false             // $17D5 STX $2B
                        edgeFlag = false                // $1854 STA $0E
                        continue outline                // $1869 JMP $15AD
                    }

                    proposeStep(&s)
                    direction = directionIndex(s, horizontalBase: horizontalBase,
                                               verticalBase: verticalBase)
                    stalls += 1
                }

                // $25EF: clear the tried set, then mark **two** slots — the
                // direction just proposed, and slot 4. `$25F8 STY $30` stores the
                // `$FF` the clearing loop left in Y into the middle of the array,
                // so "no movement" is permanently marked and the picker at `$2619`
                // can never draw it. Leaving slot 4 free lets the port pick a
                // direction the original would have rejected and redrawn for,
                // which desynchronizes the generator.
                tried = [UInt8](repeating: 0, count: 9)
                tried[4] = 0xFF
                tried[Int(direction) % 9] = 0xFF

                // `$1E`, the attempt counter. Its invariant is the one thing that
                // makes the unwind work: it always equals the number of marked
                // slots, which is why an unwind can resume a half-finished search
                // simply by recounting the record it restored.
                var attempts = 2

                while true {
                    if propose(&s, direction: direction,
                               horizontalBase: horizontalBase,
                               verticalBase: verticalBase, edgeGuard: edgeFlag),
                       accepts(&s, in: mask) {
                        break proposal                      // $2608 JMP $15AD
                    }

                    // $260B: one more attempt used. Note where `$16D1` returns
                    // to — `$2616 JMP $260B`, *not* `$2603`. So an unwind is
                    // followed by another `INC $1E` and another bounds check, and
                    // a restored position that had already tried all nine
                    // directions unwinds again immediately. That extra pass is
                    // what a straightforward reading misses, and it is why the
                    // island's deep unwind stopped one step short.
                    attempts += 1
                    while attempts >= 10 {                  // $260F CMP #$0A
                        switch unwind(&s, ring: ring, tried: &tried,
                                      ringWrapped: ringWrapped, in: &mask,
                                      erase: erase, startSlot: startSlot) {
                        case .restored:
                            attempts = tried.reduce(0) { $0 + ($1 != 0 ? 1 : 0) } + 1
                        case .restart:
                            edgeFlag = false                // $16E0 STA $0E
                            continue proposal               // $16E4 JMP $24FD
                        case .abandon:
                            // $16E9 JMP $1A48 — a recovery, not an ending.
                            recover(&s, in: &mask, edgeFlag: &edgeFlag,
                                    plot: plot, erase: erase)
                            ringWrapped = false             // $1B27 STX $2B
                            continue proposal               // $1B38 JMP $24FD
                        }
                    }

                    // $2619: pick a direction not yet tried. The invariant above
                    // guarantees at least one free slot whenever this is reached.
                    var pick = s.rng.nextModulo(9)
                    while tried[Int(pick) % 9] != 0 { pick = s.rng.nextModulo(9) }
                    direction = pick
                    tried[Int(pick) % 9] &+= 1
                }
            }
        }
        return .exhausted
    }

    /// What `$16D1` did.
    enum Unwound {
        /// A record was restored and revalidated; the search resumes from it.
        case restored
        /// The walk backed all the way out to the first slot with the heading
        /// still zero, so the original discards the search and re-proposes from
        /// the origin (`$16E4 JMP $24FD`).
        case restart
        /// Nothing left to undo (`$16E9 JMP $1A48`).
        case abandon
    }

    /// Backtracks one or more steps (`$16D1`).
    ///
    /// Keeps unwinding while the restored position fails revalidation, and the
    /// order within each pass is not the intuitive one. The cell erased is the one
    /// the walk is standing on *now*, before anything is restored (`$16F0`
    /// precedes `$16F3`); the record is then read from the current slot and only
    /// afterwards is the counter decremented. Restoring first erases the wrong
    /// cell, which is how the island diverged at plot 79.
    static func unwind(_ s: inout WalkerState, ring: [UndoRecord?],
                       tried: inout [UInt8], ringWrapped: Bool,
                       in mask: inout LandMask,
                       erase: (UInt8, Int) -> Void, startSlot: UInt8) -> Unwound {
        while true {
            // $16D3: back at the first slot without the ring ever having wrapped
            // means every step taken has been undone. `$50` is zero throughout the
            // outline trace — it is the flood fill's flag — so the choice is on the
            // heading alone: still in the first quadrant, start over; otherwise
            // give up on this landmass.
            if !ringWrapped && s.step == 0 {
                return s.heading == 0 ? .restart : .abandon
            }
            // $16EC: the ring is full — unwinding has come right around to the
            // slot this search started from.
            if s.step == startSlot { return .abandon }

            // $16F0 JSR $1B3B: erase where the walk is standing.
            let standing = cell(offset: s.offset, heading: s.heading,
                                centerX: s.centerX, centerY: s.centerY)
            mask.clearLand(x: standing.x, y: standing.y)
            erase(standing.x, standing.y)

            // $16F3: read the record, then step the counter back.
            guard let record = ring[Int(s.step)] else { return .abandon }
            tried = record.tried
            s.offset = record.offset
            s.heading = record.heading
            s.step = s.step == 0 ? UInt8(ringCapacity - 1) : s.step &- 1

            // $1722: revalidate, and unwind again if it refuses.
            if isCandidateClear(&s, in: mask) { return .restored }
        }
    }

    /// Leaves the first continent and starts the partner (`$17C8`).
    ///
    /// This is how configuration 1 gets two continents from one placement. When
    /// the walk has run `$4E` cells along the first continent's second quadrant,
    /// it stops walking a circle and draws an **isthmus** instead: a one-cell
    /// column, extended row by row down the coast, each row stepping left until
    /// both the cell and its left neighbour are water. It draws
    /// `random(radius / 8) + 5` rows and then keeps going until ten clear cells
    /// stand to the left of the last one.
    ///
    /// Where that ends becomes the partner's centre — the same column, and
    /// `radius` rows further down — and the walk restarts from scratch there, with
    /// `$50` set so the walk knows to come back.
    static func buildIsthmus(_ s: inout WalkerState, in mask: inout LandMask,
                             plot: (UInt8, Int) -> Void) {
        // $17C8: the first continent's geometry, to be picked up again later.
        s.partner = WalkerState.Partner(workingRadius: s.workingRadius,
                                        centerX: s.centerX, centerY: s.centerY,
                                        shape: s.shape)
        s.step = 0xFF                                       // $17D1 STX $46
        s.pairOffset = 0xFF                                 // $17D3, so this fires once

        // $17D7: how many rows of isthmus before the clearance test starts.
        var remaining = s.rng.nextModulo(s.workingRadius >> 3) &+ 5
        var drawn = (x: UInt8(0), y: 0)

        while true {
            // $17E4: down a row, then left until there is water here and to the
            // left. Both tests are in the row the resolve just addressed.
            s.offset.dy &+= 1
            while true {
                drawn = cell(offset: s.offset, heading: s.heading,
                             centerX: s.centerX, centerY: s.centerY)
                if !mask.isLand(x: drawn.x, y: drawn.y)
                    && !mask.isLand(x: drawn.x &- 1, y: drawn.y) { break }
                s.offset.dx &-= 1                           // $17F2
            }
            mask.setLand(x: drawn.x, y: drawn.y)            // $17FF
            plot(drawn.x, drawn.y)

            remaining &-= 1
            if remaining != 0 { continue }                  // $1809

            // $180D: ten clear cells to the left, or draw another row. The
            // original sets the counter to one rather than resetting it, so a
            // failure costs exactly one more row.
            var probe = drawn.x &- 1
            var clear = 10
            while clear > 0 && !mask.isLand(x: probe, y: drawn.y) {
                probe &-= 1
                clear -= 1
            }
            if clear == 0 { break }
            remaining = 1                                   // $1816 INC $02
        }

        // $1825: the partner's centre is where the isthmus ended, a radius
        // further down, and the first continent's centre becomes a wall the
        // partner may not cross.
        s.bridgeLimit = s.centerX &+ 5
        s.centerX = drawn.x
        s.switchRow = UInt16(truncatingIfNeeded: drawn.y) &+ 30
        s.centerY = UInt16(truncatingIfNeeded: drawn.y) &+ UInt16(s.workingRadius)
        // $1866 JSR $1B5F: and that centre goes into the position tables now.
        s.isthmusLandmass = WalkerState.IsthmusLandmass(column: s.centerX,
                                                        row: s.centerY)

        // $184E: restart the walk from the top of the new circle.
        s.candidate = Offset(dx: 0, dy: s.workingRadius)
        s.heading = 0
        adjustDrift(&s)                                     // $185A
        recomputeShape(&s)                                  // $185D
        s.mode = true                                       // $1860
    }

    /// Hands control back to the first continent (`$186C`).
    ///
    /// The partner's walk has climbed back above the switch row, so the original
    /// restores the geometry it saved at `$17C8`, works out where the walk
    /// currently stands *relative to that centre*, picks the quadrant from the two
    /// signs, and carries on. The working radius stays the partner's — `$187C`
    /// puts it straight back after `$1B55` has just restored it.
    static func switchBack(_ s: inout WalkerState, row: Int, column: UInt8,
                           in mask: inout LandMask, plot: (UInt8, Int) -> Void) {
        guard let partner = s.partner else { return }
        // $186E: the partner's own geometry, which `$2629` will want.
        s.partnerGeometry = WalkerState.Partner(workingRadius: s.workingRadius,
                                                centerX: s.centerX,
                                                centerY: s.centerY, shape: s.shape)
        let partnerRadius = s.workingRadius                 // $186E into $5D
        s.workingRadius = partner.workingRadius
        s.centerX = partner.centerX
        s.centerY = partner.centerY
        s.shape = partner.shape
        s.workingRadius = partnerRadius                     // $187C LDA $5D
        s.mode = false                                      // $1883
        s.step = 0                                          // $1885

        // $1888: the quadrant comes from the two signs, and equal counts as the
        // far side.
        s.heading = s.centerX > column ? 1 : 2
        s.offset.dx = s.centerX >= column ? s.centerX &- column : column &- s.centerX

        resumeFromRow(&s, row: row, in: &mask, plot: plot)
    }

    /// `$189A` — turn an absolute row into an offset, then trim the seam.
    ///
    /// Shared by the switch back and by `$1A48`'s recovery, which jumps straight
    /// here once it has found its way back onto land.
    static func resumeFromRow(_ s: inout WalkerState, row: Int,
                              in mask: inout LandMask,
                              plot: (UInt8, Int) -> Void) {
        // $189A: byte arithmetic on the row's low byte alone.
        let low = UInt8(truncatingIfNeeded: row)
        let centreLow = UInt8(truncatingIfNeeded: s.centerY)
        if low >= centreLow {
            s.offset.dy = low &- centreLow
        } else {
            s.offset.dy = centreLow &- low
            if s.heading == 2 { s.heading = 3 }
        }
        recomputeShape(&s)                                  // $18AF

        // $18B2: trim the seam. Walking up from the join, land is erased and
        // water is redrawn one cell at a time until the walk is back inside the
        // shape parameter.
        while s.offset.dy >= s.shape {
            let above = Offset(dx: s.offset.dx, dy: s.offset.dy &- 1)
            let probe = cell(offset: above, heading: s.heading,
                             centerX: s.centerX, centerY: s.centerY)
            if mask.isLand(x: probe.x, y: probe.y) {
                let standing = cell(offset: s.offset, heading: s.heading,
                                    centerX: s.centerX, centerY: s.centerY)
                mask.clearLand(x: standing.x, y: standing.y)    // $18CA
                s.offset.dy &-= 1
                continue
            }
            // $18D7: step up, and pull left if the cell to the right is water.
            s.offset.dy &-= 1
            let right = Offset(dx: s.offset.dx &+ 1, dy: s.offset.dy)
            let beside = cell(offset: right, heading: s.heading,
                              centerX: s.centerX, centerY: s.centerY)
            if mask.isLand(x: beside.x, y: beside.y) { s.offset.dx &-= 1 }
            let here = cell(offset: s.offset, heading: s.heading,
                            centerX: s.centerX, centerY: s.centerY)
            mask.setLand(x: here.x, y: here.y)                  // $18E9
            plot(here.x, here.y)
        }
        recomputeShape(&s)                                  // $18F6
        s.pairOffset = 0xFF
    }

    /// The walk has run out of both directions and ring, and finds its way back
    /// (`$1A48`).
    ///
    /// This is not the giving-up path it looks like. `$16D1`'s two `PLA / PLA`
    /// exits both land here, and what happens is a *recovery*: erase where the
    /// walk stands, cast about below and to the right for the nearest land, work
    /// out which quadrant that puts it in, and carry on from there with a fresh
    /// ring. A port that treats the exit as the end of the walk simply stops
    /// early — for a paired continent, several hundred cells early.
    static func recover(_ s: inout WalkerState, in mask: inout LandMask,
                        edgeFlag: inout Bool, plot: (UInt8, Int) -> Void,
                        erase: (UInt8, Int) -> Void) {
        // $1A48: erase where it stands, and remember where that was — `$1B3B`
        // leaves the resolved cell in `$0C`/`$08`, which is what `$1A69` starts
        // from.
        let standing = cell(offset: s.offset, heading: s.heading,
                            centerX: s.centerX, centerY: s.centerY)
        mask.clearLand(x: standing.x, y: standing.y)
        erase(standing.x, standing.y)

        // $1A4B: while tracing the partner's last quadrant, the recovery runs as
        // a subroutine — `$1B38` is patched to `RTS` — and control then goes to
        // `$189A` rather than to the proposal.
        let viaSwitch = s.paired && s.mode && s.heading >= 3
        let row = regainLand(&s, from: standing, in: mask, edgeFlag: &edgeFlag)
        if viaSwitch { resumeFromRow(&s, row: row, in: &mask, plot: plot) }
    }

    /// Finds land again and re-enters the walk from it (`$1A69`).
    ///
    /// Scans three cells across and then a row down, starting one cell up and to
    /// the left of where the walk stood, until it lands on something. The quadrant
    /// falls out of the two comparisons at `$1AAF` and `$1AB8`, in exactly the
    /// pattern `$13E0` decodes.
    ///
    /// - Returns: the row it settled on.
    @discardableResult
    static func regainLand(_ s: inout WalkerState, from standing: (x: UInt8, y: Int),
                           in mask: LandMask, edgeFlag: inout Bool) -> Int {
        var column = standing.x &- 1                        // $1A69 DEC $0C
        var row = standing.y - 1                            // $1A6F, 16-bit
        var probe = column

        // $1A77: three across, then down a row.
        scan: while true {
            var tried = 0                                   // $26
            while true {
                if mask.isLand(x: probe, y: row) { break scan }
                tried += 1
                if tried == 3 { break }
                probe &+= 1
                if probe == 0 { break }                     // $1A95 BNE
            }
            probe = column
            row += 1
            if row > LandMask.addressableRows { break }
        }
        column = probe                                      // $1AA3

        // $1AA7: heading 0 with the column already on the centre keeps what it
        // has; otherwise the quadrant comes from the two signs.
        if s.heading != 0 || column != s.centerX {
            reheading(&s, column: column, row: row)

            // $1ACC: still on the partner, back in the first quadrant, and above
            // the centre by more than the shape — that is far enough north to
            // hand back to the first continent outright.
            if s.mode && s.heading == 0
                && Int(s.centerY) - Int(s.shape) >= row, let partner = s.partner {
                s.mode = false                              // $1AEB INC $50
                s.workingRadius = partner.workingRadius     // $1AED JSR $1B55
                s.centerX = partner.centerX
                s.centerY = partner.centerY
                s.shape = partner.shape
                reheading(&s, column: column, row: row)     // $1AF0 BMI $1AAF
            }
        }

        // $1AF2: back to an offset from whichever centre is now current.
        s.offset.dx = s.heading < 2 ? s.centerX &- column : column &- s.centerX
        let low = UInt8(truncatingIfNeeded: row)
        let centreLow = UInt8(truncatingIfNeeded: s.centerY)
        s.offset.dy = (s.heading == 0 || s.heading == 3) ? centreLow &- low
                                                         : low &- centreLow

        // $1B22: a fresh ring, and the edge flag cleared unless the candidate is
        // already clear of the left edge.
        s.step = 0
        if s.heading & 1 == 0 && s.candidate.dx < 2 { edgeFlag = false }
        return row
    }

    /// `$1AAF` — the quadrant, from where the walk is against where the centre is.
    private static func reheading(_ s: inout WalkerState, column: UInt8, row: Int) {
        var heading: UInt8 = column < s.centerX ? 1 : 2
        if Int(s.centerY) >= row { heading = heading == 1 ? 0 : 3 }
        s.heading = heading
    }

    /// Closes the outline with a vertical run (`$1648`).
    ///
    /// Steps `dy` from wherever the walk finished toward the radius, drawing at
    /// `dx = 0` each time, and stops on reaching it. This is the seam where the
    /// four quadrants meet, and without it a coastline is left open.
    ///
    /// The original picks the direction by **patching its own loop**: `$1654`
    /// writes either `$E6` (`INC`) or `$C6` (`DEC`) into `$1657` depending on
    /// whether `dy` is below or above the radius. Transcribed as a signed step
    /// rather than reproduced literally, since the effect is a direction and
    /// nothing else reads those bytes.
    ///
    /// It plots with `dx = 0` taken from the accumulator (`LDA #$00`), not from
    /// `$14`, which still holds the walk's last value — the distinction that
    /// mislabelled four events when the reference fixture was first captured.
    static func spanFill(_ s: inout WalkerState, in mask: inout LandMask,
                         plot: (UInt8, Int) -> Void) {
        guard s.offset.dy != s.radius else { return }
        let rising = s.offset.dy < s.radius
        while true {
            s.offset.dy = rising ? s.offset.dy &+ 1 : s.offset.dy &- 1
            if s.offset.dy == s.radius { return }
            let (column, row) = cell(offset: Offset(dx: 0, dy: s.offset.dy),
                                     heading: s.heading,
                                     centerX: s.centerX, centerY: s.centerY)
            mask.setLand(x: column, y: row)
            plot(column, row)
        }
    }

    /// Whether the evaluator accepts the current candidate (`$1516`-`$1554`).
    ///
    /// Four separate refusals, and omitting the last two is not cosmetic: a
    /// wrongly accepted candidate changes how many directions the search tries,
    /// which changes how many numbers it draws, which shifts the whole
    /// subsequent walk. An early version of this checked only the first two and
    /// the island diverged at plot 9.
    ///
    /// 1. `$1516` — two or more neighbors refuses. The walk keeps to thin
    ///    coastline; area is filled later by the span and flood passes.
    /// 2. `$151A` — either offset reaching `$FF`, i.e. having wrapped past zero.
    /// 3. `$152D` — the resolved column being 0 or `$FF`, keeping the outline
    ///    off the map's vertical edges.
    /// 4. `$1547` — the resolved row being 0, or at least `$018F` when it has
    ///    crossed 256. That second bound is 399, the last row of the map.
    static func accepts(_ s: inout WalkerState, in mask: LandMask) -> Bool {
        let (column, row) = cell(offset: s.candidate, heading: s.heading,
                                 centerX: s.centerX, centerY: s.centerY)
        let origin = scanOrigin(column: column, row: row)
        if neighborCount(fromColumn: origin.column, row: origin.row, in: mask) >= 2 {
            return false
        }
        if s.candidate.dx == 0xFF || s.candidate.dy == 0xFF { return false }
        if column == 0 || column == 0xFF { return false }

        // $1537: while tracing the partner, nothing may be drawn left of the
        // first continent's centre plus five. Dead code in every configuration
        // but 1, which is why it went unnoticed until the pair was ported.
        if s.mode && s.heading == 3 && column < s.bridgeLimit { return false }

        // $1547: the row is 16-bit, and the two halves are checked differently.
        let value = UInt16(bitPattern: Int16(truncatingIfNeeded: row))
        if value & 0xFF00 != 0 { return value & 0xFF < 0x8F }
        return value & 0xFF != 0
    }
}
