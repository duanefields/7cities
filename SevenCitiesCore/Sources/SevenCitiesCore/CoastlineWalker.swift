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
