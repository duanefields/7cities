/// The World Maker's arithmetic helpers.
///
/// The 6502 has no multiply or divide instruction, so the original carries its
/// own. Both are transcribed literally from `game3`, including their overflow
/// behavior — downstream generation code depends on exactly these results,
/// wrong answers included, so "fixing" them would break fidelity.
public enum Arithmetic {

    /// 8x8 to 16-bit multiply, from `$0A51`.
    ///
    /// The original takes the multiplicand in A and the multiplier in Y, and
    /// returns the low byte in A with the high byte in Y. Shift-and-add.
    public static func multiply(_ multiplicand: UInt8,
                                _ multiplier: UInt8) -> (low: UInt8, high: UInt8) {
        var multiplier = multiplier
        var high: UInt8 = 0
        var low: UInt8 = 0

        for _ in 0..<8 {
            // LSR $03 — carry takes the multiplier's low bit.
            var carry = multiplier & 1 != 0
            multiplier >>= 1

            if carry {
                // CLC / ADC $02
                let sum = UInt16(high) + UInt16(multiplicand)
                high = UInt8(truncatingIfNeeded: sum)
                carry = sum > 0xFF
            }

            // ROR A / ROR $04 — shift the 16-bit accumulator right through carry.
            let carryOut = high & 1 != 0
            high = (carry ? 0x80 : 0) | (high >> 1)
            low = (carryOut ? 0x80 : 0) | (low >> 1)
        }

        return (low, high)
    }

    /// 16-by-8 restoring divide, from `$0A6E`.
    ///
    /// The original takes the divisor in X and the dividend as Y (high) and
    /// A (low), returning the quotient in A and the remainder in Y.
    ///
    /// Note the `ROL A` inside the loop discards its carry out. When the high
    /// byte is greater than or equal to the divisor the quotient overflows and
    /// the result is garbage — that is the original's behavior and is preserved
    /// deliberately. Callers in `game3` avoid it by keeping the high byte small.
    public static func divide(high: UInt8, low: UInt8,
                              by divisor: UInt8) -> (quotient: UInt8, remainder: UInt8) {
        var quotient = low
        var remainder = high

        for _ in 0..<8 {
            // ASL $03 / ROL A
            let carry = quotient & 0x80 != 0
            quotient <<= 1
            remainder = (remainder << 1) | (carry ? 1 : 0)

            // CMP $02 / BCC / SBC $02 / INC $03
            if remainder >= divisor {
                remainder &-= divisor
                quotient &+= 1
            }
        }

        return (quotient, remainder)
    }
}
