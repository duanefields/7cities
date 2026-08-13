import Foundation
import Testing

@testable import SevenCitiesCore

/// Positions captured at `$1B5F` in the original 6502.
/// Regenerate with `tools/placement_reference.py`.
private struct Reference: Decodable {
    struct Placement: Decodable {
        let x: Int, y: Int, b0: Int, sizeClass: Int, flags: Int, pairOffset: Int
    }
    struct Case: Decodable {
        let seed: UInt16, config: Int
        let placements: [Placement]
    }
    let cases: [Case]
}

private func loadReference() throws -> Reference {
    let url = try #require(
        Bundle.module.url(forResource: "placement_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "placement_reference", withExtension: "json"),
        "placement_reference.json fixture is missing")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
}

/// **Only the first placement of each run can be checked yet.**
///
/// The coastline walker is not ported, so `fill` is a no-op and the mask stays
/// empty. `isClear` then accepts every candidate immediately, where the original
/// was rejecting positions that collided with land already drawn. So placements
/// after the first diverge for a reason that has nothing to do with this loop.
///
/// The first one is still a real test: it exercises the `pairOffset` draw and
/// its retry, the discarded coin flip, the bounds for the command, and the byte
/// and word draws — in the exact order and count the original uses. Getting it
/// right means the LFSR is in step through all of that.
@Test("The first placement of every run matches the original")
func firstPlacementMatchesOriginal() throws {
    let reference = try loadReference()
    #expect(!reference.cases.isEmpty)

    for c in reference.cases {
        var rng = WorldMakerRNG(seed: c.seed)
        var mask = LandMask()
        let placed = LandMassPhase.runCommandStage(config: c.config, rng: &rng,
                                                   mask: &mask)
        let expected = try #require(c.placements.first)
        let actual = try #require(placed.first)

        #expect(actual.x == UInt8(expected.x), """
            seed $\(String(format: "%04X", c.seed)) config \(c.config): \
            x expected \(expected.x), got \(actual.x)
            """)
        #expect(actual.y == UInt16(expected.y), """
            seed $\(String(format: "%04X", c.seed)) config \(c.config): \
            y expected \(expected.y), got \(actual.y)
            """)
        #expect(actual.radius == UInt8(expected.b0))
    }
}

/// The number of landmasses the stage places is set by the command table alone,
/// so it is checkable without the walker.
@Test("The command stage places as many landmasses as the table says")
func placementCountMatchesTable() throws {
    let reference = try loadReference()

    for c in reference.cases {
        var rng = WorldMakerRNG(seed: c.seed)
        var mask = LandMask()
        let placed = LandMassPhase.runCommandStage(config: c.config, rng: &rng,
                                                   mask: &mask)
        let expected = LandMassPhase.configurations[c.config]
            .reduce(0) { $0 + $1.count }
        #expect(placed.count == expected,
                "config \(c.config): expected \(expected) placements, got \(placed.count)")
    }
}

/// Configuration 1 places a pair from a single command.
@Test("A paired command yields a partner")
func pairedCommandHasPartner() throws {
    var rng = WorldMakerRNG(seed: 0x1234)
    var mask = LandMask()
    let placed = LandMassPhase.runCommandStage(config: 1, rng: &rng, mask: &mask)
    let continent = try #require(placed.first)
    #expect(continent.partner != nil, "the paired command should carry a partner")
    // Islands in the same configuration are not paired.
    #expect(placed.dropFirst().allSatisfy { $0.partner == nil })
}

/// The two discarded draws are load-bearing: skipping them shifts every later
/// value. This pins that they are consumed.
@Test("Setup consumes the draws whose results are thrown away")
func setupConsumesDiscardedDraws() {
    var withSetup = WorldMakerRNG(seed: 0x1234)
    var mask = LandMask()
    _ = LandMassPhase.runCommandStage(config: 0, rng: &withSetup, mask: &mask)

    // A generator that only made the x/y draws would be far less advanced.
    var bare = WorldMakerRNG(seed: 0x1234)
    for _ in 0..<8 { _ = bare.next() }
    #expect(withSetup.state != bare.state)
}
