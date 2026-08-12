import Foundation
import Testing

@testable import SevenCitiesCore

/// Reference output captured by executing the *original* `$22B4` and `$247B`
/// inside VICE. Regenerate with `tools/randrange_reference.py`.
private struct Reference: Decodable {
    struct Case: Decodable {
        let seed: UInt16
        let lo: Int
        let hi: Int
        let value: Int
    }
    let byteCases: [Case]
    let wordCases: [Case]
}

private func loadReference() throws -> Reference {
    let url = try #require(
        Bundle.module.url(forResource: "randrange_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "randrange_reference", withExtension: "json"),
        "randrange_reference.json fixture is missing")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
}

/// The 8-bit cases were captured from a **single** seeding, with the ten ranges
/// drawn one after another, so they have to be replayed in order against one
/// generator. Reseeding per case would pass a weaker test: rejection consumes a
/// variable number of LFSR steps, and replaying the sequence is what proves the
/// port throws away the same candidates the original did.
@Test("Byte draws match the original 6502 across a whole sequence")
func byteDrawsMatchOriginal() throws {
    let reference = try loadReference()
    #expect(!reference.byteCases.isEmpty)

    var seeds: [UInt16] = []
    for c in reference.byteCases where !seeds.contains(c.seed) { seeds.append(c.seed) }

    for seed in seeds {
        var rng = WorldMakerRNG(seed: seed)
        for (step, c) in reference.byteCases.filter({ $0.seed == seed }).enumerated() {
            let actual = rng.nextByte(from: UInt8(c.lo), below: UInt8(c.hi))
            #expect(Int(actual) == c.value, """
                seed $\(String(format: "%04X", seed)) step \(step) \
                range \(c.lo)..<\(c.hi): expected \(c.value), got \(actual)
                """)
        }
    }
}

/// Each 16-bit case was captured from its own fresh seeding.
@Test("Word draws match the original 6502")
func wordDrawsMatchOriginal() throws {
    let reference = try loadReference()
    #expect(!reference.wordCases.isEmpty)

    for c in reference.wordCases {
        var rng = WorldMakerRNG(seed: c.seed)
        let actual = rng.nextWord(from: UInt16(c.lo), below: UInt16(c.hi))
        #expect(Int(actual) == c.value, """
            seed $\(String(format: "%04X", c.seed)) range \(c.lo)..<\(c.hi): \
            expected \(c.value), got \(actual)
            """)
    }
}

/// `$22BA` returns the lower bound without drawing when `lo >= hi`. Getting this
/// wrong would not just return a wrong value — it would desynchronize the LFSR
/// for every later draw.
@Test("An empty or inverted byte range yields its lower bound without drawing")
func emptyByteRangeDoesNotDraw() {
    var rng = WorldMakerRNG(seed: 0x1234)
    let before = rng.state
    #expect(rng.nextByte(from: 5, below: 5) == 5)
    #expect(rng.nextByte(from: 200, below: 100) == 200)
    #expect(rng.state == before, "the register must not advance")
}

/// The high byte comes from the sign of a second draw, so results never exceed
/// 511 — which is exactly enough for the map's 400 rows.
@Test("Word draws never exceed the 9 bits the original can produce")
func wordDrawsAreNineBits() {
    var rng = WorldMakerRNG(seed: 0xA55A)
    for _ in 0..<200 {
        #expect(rng.nextWord(from: 0, below: 512) <= 511)
    }
}
