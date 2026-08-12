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

/// Bounded draws, as the World Maker makes them.
///
/// Both are **rejection samplers**: they keep advancing the register until a
/// value lands inside the range, rather than reducing one draw by modulo or
/// scaling. That distinction is not cosmetic — rejection consumes a variable
/// number of LFSR steps, so every later draw in the sequence depends on how
/// many candidates were thrown away. Reproducing the original's worlds requires
/// reproducing the waste.
///
/// Transcribed from `$22B4` and `$247B` in `game3`. Both are self-modifying
/// there: `$22B4` writes its bounds into the operand bytes of its own two `CMP`
/// instructions at `$22E8` and `$22EC`, which is why a plain reading of the
/// listing shows `CMP #$FF` twice.
extension WorldMakerRNG {

    /// A byte in `from ..< below`, by rejection (`$22B4`).
    ///
    /// When `from >= below` this returns `from` without advancing the register,
    /// matching the guard at `$22BA` (`CMP $22EC / BCS`).
    ///
    /// The bounds are two parameters rather than a `Range` deliberately. Swift's
    /// `Range` traps at construction when inverted, so it cannot represent the
    /// case the original explicitly handles — expressing these bounds as a
    /// `Range` would impose an invariant the 6502 does not have and turn a
    /// reachable path into a crash.
    public mutating func nextByte(from lower: UInt8, below upper: UInt8) -> UInt8 {
        guard lower < upper else { return lower }
        while true {
            let value = next()
            if value >= lower && value < upper { return value }
        }
    }

    /// A 16-bit value in `from ..< below`, by rejection (`$247B`).
    ///
    /// Two register advances per candidate, not one. The first supplies the low
    /// byte; the second is drawn only for its **sign**, and the high byte is 1
    /// when that draw is below `$80` and 0 otherwise (`LDA $CF / BMI / INX` at
    /// `$24E1`). That caps the result at 511, which is all the map's 400 rows
    /// need. A rejected candidate re-draws both.
    ///
    /// The original only short-circuits when the bounds are exactly equal, so an
    /// inverted range spins forever. That hazard is preserved rather than
    /// papered over — every caller derives its bounds from a landmass radius and
    /// cannot invert them — but it is a hang, not merely a wrong answer, so a
    /// new caller must not pass one.
    public mutating func nextWord(from lower: UInt16, below upper: UInt16) -> UInt16 {
        // $247F / $2487: equal bounds return the lower bound unsampled.
        if lower == upper { return lower }
        while true {
            let low = next()
            let high: UInt8 = next() < 0x80 ? 1 : 0
            let value = UInt16(high) << 8 | UInt16(low)
            if value >= lower && value < upper { return value }
        }
    }
}
