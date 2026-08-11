/// The World Maker's pseudo-random number generator.
///
/// Transcribed from the original 6502 routine at `$0AE2` in `game3` (Ozark
/// Softscape, 1984). It is a 16-bit linear feedback shift register held in
/// zero page: `$CD` is the high byte, `$CF` the low byte. Each call shifts the
/// register eight times and returns the low byte.
///
/// The transcription is deliberately literal rather than simplified. `ROL` on
/// the 6502 is a *nine-bit* rotate through the carry flag, and the feedback
/// taps are read after four such rotates — reasoning that through algebraically
/// is easy to get subtly wrong, so the shape of the original is preserved.
///
/// The original additionally stirred `$CD` with live SID noise (`$D41B`) from
/// its raster interrupt handler, which made any particular world impossible to
/// reproduce even on real hardware. That stirring is intentionally *not*
/// reproduced here: seeding is explicit, so a given seed always yields the same
/// world.
public struct WorldMakerRNG: Sendable {

    /// High byte of the shift register (`$CD` in the original).
    public private(set) var high: UInt8

    /// Low byte of the shift register (`$CF` in the original).
    public private(set) var low: UInt8

    /// The current register state as a single 16-bit value.
    public var state: UInt16 { UInt16(high) << 8 | UInt16(low) }

    /// Creates a generator seeded with a 16-bit value.
    ///
    /// The original seeded this by reading the SID's oscillator twice, giving
    /// 65,536 distinct worlds.
    public init(seed: UInt16) {
        self.high = UInt8(truncatingIfNeeded: seed >> 8)
        self.low = UInt8(truncatingIfNeeded: seed)
    }

    /// Creates a generator from the raw zero-page byte pair.
    public init(high: UInt8, low: UInt8) {
        self.high = high
        self.low = low
    }

    /// 6502 `ROL`: a nine-bit rotate left through carry.
    ///
    /// Returns the rotated value and the bit shifted out into carry.
    private static func rol(_ value: UInt8, _ carryIn: Bool) -> (UInt8, Bool) {
        let out = value & 0x80 != 0
        return ((value << 1) | (carryIn ? 1 : 0), out)
    }

    /// Advances the register eight steps and returns the next value.
    public mutating func next() -> UInt8 {
        for _ in 0..<8 {
            // CLC / LDA $CD / ROL A x4 / AND #$02 / STA $CE
            var rotated = high
            var carry = false
            for _ in 0..<4 {
                (rotated, carry) = Self.rol(rotated, carry)
            }
            let tapHigh = rotated & 0x02

            // LDA $CF / AND #$02 / CLC / EOR $CE / BEQ +1 / SEC
            let tapLow = low & 0x02
            let feedback = (tapLow ^ tapHigh) != 0

            // ROL $CF / ROL $CD — 16-bit shift, low byte first.
            let (newLow, carryOut) = Self.rol(low, feedback)
            low = newLow
            (high, _) = Self.rol(high, carryOut)
        }

        // LDA $CD / ORA $CF / BNE +2 / INC $CD — never rest at all zeros.
        if high | low == 0 {
            high &+= 1
        }

        return low
    }
}
