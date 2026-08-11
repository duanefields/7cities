import Foundation
import Testing

@testable import SevenCitiesCore

/// Reference output captured by executing the *original* 6502 routine inside
/// VICE. Regenerate with `tools/rng_reference.py`.
private struct Reference: Decodable {
    struct Sequence: Decodable {
        let seed_cd: UInt8
        let seed_cf: UInt8
        let values: [UInt8]
        let states: [[UInt8]]
    }
    let routine: String
    let sequences: [Sequence]
}

private func loadReference() throws -> Reference {
    let url = try #require(
        Bundle.module.url(forResource: "rng_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "rng_reference", withExtension: "json"),
        "rng_reference.json fixture is missing")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
}

@Test("Swift LFSR matches the original 6502 output for every seed")
func matchesOriginalSequences() throws {
    let reference = try loadReference()
    #expect(!reference.sequences.isEmpty)

    for sequence in reference.sequences {
        var rng = WorldMakerRNG(high: sequence.seed_cd, low: sequence.seed_cf)
        for (index, expected) in sequence.values.enumerated() {
            let actual = rng.next()
            #expect(actual == expected, """
                seed $\(String(format: "%02X%02X", sequence.seed_cd, sequence.seed_cf)) \
                step \(index): expected $\(String(format: "%02X", expected)), \
                got $\(String(format: "%02X", actual))
                """)
        }
    }
}

@Test("Internal register state tracks the original zero page bytes")
func matchesOriginalState() throws {
    let reference = try loadReference()

    for sequence in reference.sequences {
        var rng = WorldMakerRNG(high: sequence.seed_cd, low: sequence.seed_cf)
        for (index, expected) in sequence.states.enumerated() {
            _ = rng.next()
            #expect(rng.high == expected[0], "seed step \(index): $CD mismatch")
            #expect(rng.low == expected[1], "seed step \(index): $CF mismatch")
        }
    }
}

@Test("Seeding by 16-bit value matches seeding by byte pair")
func seedingIsEquivalent() {
    var a = WorldMakerRNG(seed: 0x1234)
    var b = WorldMakerRNG(high: 0x12, low: 0x34)
    #expect(a.state == 0x1234)
    for _ in 0..<32 {
        #expect(a.next() == b.next())
    }
}

@Test("Generator never rests at the all-zero state")
func escapesZeroState() {
    var rng = WorldMakerRNG(seed: 0)
    for _ in 0..<64 {
        _ = rng.next()
        #expect(rng.state != 0, "LFSR must not lock at zero")
    }
}
