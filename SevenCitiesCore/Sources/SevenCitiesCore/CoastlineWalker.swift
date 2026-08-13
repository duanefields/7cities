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
