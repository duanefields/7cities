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

            var retry: UInt8
            repeat { retry = state.rng.next() } while retry == 0xFF
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
