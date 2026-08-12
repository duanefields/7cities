import Foundation
import Testing

@testable import SevenCitiesCore

/// Reference output captured by executing the *original* `$22F7` inside VICE.
/// Regenerate with `tools/areatest_reference.py`.
private struct Reference: Decodable {
    struct Blob: Decodable { let x: Int, y: Int, width: Int, height: Int }
    struct Case: Decodable { let x: Int, y: Int, radius: Int, clear: Bool }
    let blobs: [Blob]
    let cases: [Case]
}

private func loadReference() throws -> Reference {
    let url = try #require(
        Bundle.module.url(forResource: "areatest_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "areatest_reference", withExtension: "json"),
        "areatest_reference.json fixture is missing")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
}

/// The mask is rebuilt from the fixture's rectangles, not shipped as bytes —
/// the same land the original was given.
private func buildMask(_ blobs: [Reference.Blob]) -> LandMask {
    var mask = LandMask()
    for blob in blobs {
        for y in blob.y..<(blob.y + blob.height) {
            for x in blob.x..<(blob.x + blob.width) {
                mask.setLand(x: UInt8(x), y: y)
            }
        }
    }
    return mask
}

@Test("Placement test matches the original 6502")
func placementMatchesOriginal() throws {
    let reference = try loadReference()
    let mask = buildMask(reference.blobs)

    for c in reference.cases {
        let actual = LandMassPhase.isClear(x: UInt8(c.x), y: UInt16(c.y),
                                           radius: UInt8(c.radius), in: mask)
        #expect(actual == c.clear, """
            x=\(c.x) y=\(c.y) r=\(c.radius): \
            expected \(c.clear ? "clear" : "blocked"), \
            got \(actual ? "clear" : "blocked")
            """)
    }
}

/// A fixture of all-clear or all-blocked cases would pass against a port that
/// ignored its input entirely. An early version of this fixture was exactly
/// that — 32 cases, every one blocked — because a uniformly random mask blocks
/// everything once the cross samples hundreds of cells.
@Test("The placement fixture actually discriminates")
func fixtureHasBothOutcomes() throws {
    let reference = try loadReference()
    let clear = reference.cases.filter(\.clear).count
    #expect(clear > 0, "no accepting cases — the fixture cannot detect a port that always rejects")
    #expect(clear < reference.cases.count,
            "no rejecting cases — the fixture cannot detect a port that always accepts")
}

@Test("The three configurations are the ones the original builds")
func configurationsMatchTheCommandTable() {
    #expect(LandMassPhase.configurations.count == 3)

    // Configuration 1 is the one worth asserting: its command count is 1, yet
    // the paired flag makes it build two continents.
    let paired = LandMassPhase.configurations[1][0]
    #expect(paired.isContinent)
    #expect(paired.placesPair)
    #expect(paired.count == 1)

    let continents = LandMassPhase.configurations.map { config in
        config.filter(\.isContinent).reduce(0) { $0 + $1.count * ($1.placesPair ? 2 : 1) }
    }
    let islands = LandMassPhase.configurations.map { config in
        config.filter { !$0.isContinent }.reduce(0) { $0 + $1.count }
    }
    #expect(continents == [2, 2, 1])
    #expect(islands == [2, 2, 6])
}

@Test("Landmass radii are the original's two size classes")
func radiiMatch() {
    #expect(LandMassPhase.radius(continent: true) == 0x46)   // 70
    #expect(LandMassPhase.radius(continent: false) == 0x0A)  // 10
}

@Test("Placement bounds keep a landmass on the map")
func placementBoundsAreOnMap() {
    for continent in [true, false] {
        let r = LandMassPhase.radius(continent: continent)
        let x = LandMassPhase.xRange(radius: r)
        #expect(x.lower == r)
        #expect(Int(x.upper) == 0xFE - Int(r))

        let y = LandMassPhase.yRange(radius: r, config: 0, continent: continent)
        #expect(y.lower == UInt16(r) + 2)
        #expect(y.upper == 389 - UInt16(r))
    }
    // Configuration 2 clamps its continent to a middle band.
    let clamped = LandMassPhase.yRange(radius: 0x46, config: 2, continent: true)
    #expect(clamped == (110, 220))
}

@Test("An empty mask accepts anything")
func emptyMaskAccepts() {
    let mask = LandMask()
    #expect(LandMassPhase.isClear(x: 128, y: 200, radius: 70, in: mask))
    #expect(LandMassPhase.isClear(x: 0, y: 0, radius: 10, in: mask))
}
