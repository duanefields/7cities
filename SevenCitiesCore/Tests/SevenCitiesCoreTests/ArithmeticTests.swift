import Foundation
import Testing

@testable import SevenCitiesCore

/// Reference output captured by executing the *original* 6502 routines inside
/// VICE. Regenerate with `tools/arith_reference.py`.
private struct ArithReference: Decodable {
    struct Mul: Decodable {
        let multiplier: UInt8
        let low: [UInt8]
        let high: [UInt8]
    }
    struct Div: Decodable {
        let high: UInt8
        let divisor: UInt8
        let quotient: [UInt8]
        let remainder: [UInt8]
    }
    let multiply: [Mul]
    let divide: [Div]
}

private func loadArithReference() throws -> ArithReference {
    let url = try #require(
        Bundle.module.url(forResource: "arith_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "arith_reference", withExtension: "json"),
        "arith_reference.json fixture is missing")
    return try JSONDecoder().decode(ArithReference.self, from: Data(contentsOf: url))
}

@Test("Multiply matches the original 6502 across every sweep")
func multiplyMatchesOriginal() throws {
    let reference = try loadArithReference()
    #expect(!reference.multiply.isEmpty)

    for sweep in reference.multiply {
        for i in 0..<256 {
            let (low, high) = Arithmetic.multiply(UInt8(i), sweep.multiplier)
            #expect(low == sweep.low[i],
                    "\(i) * \(sweep.multiplier): low byte mismatch")
            #expect(high == sweep.high[i],
                    "\(i) * \(sweep.multiplier): high byte mismatch")
        }
    }
}

@Test("Divide matches the original 6502 across every sweep")
func divideMatchesOriginal() throws {
    let reference = try loadArithReference()
    #expect(!reference.divide.isEmpty)

    for sweep in reference.divide {
        for i in 0..<256 {
            let (quotient, remainder) = Arithmetic.divide(
                high: sweep.high, low: UInt8(i), by: sweep.divisor)
            #expect(quotient == sweep.quotient[i],
                    "(\(sweep.high):\(i)) / \(sweep.divisor): quotient mismatch")
            #expect(remainder == sweep.remainder[i],
                    "(\(sweep.high):\(i)) / \(sweep.divisor): remainder mismatch")
        }
    }
}

@Test("Multiply agrees with plain arithmetic where it cannot overflow")
func multiplyIsCorrectWhereDefined() {
    for a in 0..<256 {
        for b in [0, 1, 2, 3, 7, 10, 90, 255] {
            let (low, high) = Arithmetic.multiply(UInt8(a), UInt8(b))
            let product = UInt16(low) | UInt16(high) << 8
            #expect(product == UInt16(a) * UInt16(b))
        }
    }
}
