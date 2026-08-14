import CryptoKit
import Foundation
import Testing

@testable import SevenCitiesCore

/// The band the terrain pipeline starts from, built out of the land mask the port
/// already reproduces.
///
/// This is the join between the two halves of the World Maker: the land-mass
/// phase ends with a 1-bit mask, `$0C9B` unpacks it into nibbles in the same
/// memory, and everything after works on those. Matching the original's band here
/// means the terrain phases can be ported against captured digests without having
/// to reproduce the band writer first.
///
/// Only the **first** band can be checked this way. The second starts at row 192
/// and overlaps the first by sixteen rows, and by the time it is loaded those
/// sixteen already carry terrain the first band's phases generated — so its input
/// is not a function of the mask alone, and it cannot be built until those phases
/// exist.
private struct Reference: Decodable {
    struct Step: Decodable {
        let phase: String
        let sha256: String
        let rng: Int
        let band: Int
        let nibbles: [String: Int]
    }
    let seed: Int
    let config: Int
    let bandRows: Int
    let bands: [[Step]]
}

private func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

@Test("The first band is the land mask unpacked into nibbles")
func firstBandMatchesOriginal() throws {
    let url = try #require(
        Bundle.module.url(forResource: "terrain_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "terrain_reference", withExtension: "json"),
        "terrain_reference.json fixture is missing")
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    #expect(reference.bandRows == TerrainBand.rows)

    let run = try LandMassStage.run(config: reference.config,
                                    seed: UInt16(reference.seed))
    let band = TerrainBand(landMask: run.mask, fromRow: 0)

    let entry = try #require(reference.bands.first?.first)
    #expect(entry.phase == "islands", "the pipeline's first phase moved")
    #expect(sha256(band.storage) == entry.sha256,
            "the unpacked band differs from the original's")

    // The histogram is only water and plain at this point, which is what makes
    // the unpack a one-line rule rather than a table.
    let histogram = band.histogram.filter { $0.value > 0 }
    #expect(Set(histogram.keys) == [0x0, 0xB])
    for (nibble, count) in histogram {
        #expect(entry.nibbles[String(format: "%X", nibble)] == count)
    }
}

/// Reading and writing a cell, against the halves `$0FAE` picks.
@Test("Nibble addressing puts even columns in the high half")
func nibbleAddressing() {
    var band = TerrainBand()
    band[4, 3] = 0xC
    band[5, 3] = 0xD
    #expect(band[4, 3] == 0xC)
    #expect(band[5, 3] == 0xD)
    // $0FAE: row * 128 + column / 2, and the even column is the high nibble.
    #expect(band.storage[3 * 128 + 2] == 0xCD)
    // Outside the band, reads are water and writes go nowhere.
    band[0, TerrainBand.rows] = 0xF
    #expect(band[0, TerrainBand.rows] == 0)
}

/// `$2A45`, against every distinct box the original computed in a whole run.
@Test("Bounding boxes clamp the way the original clamps them")
func boundingBoxesMatchOriginal() throws {
    struct Case: Decodable {
        let radius: Int, x: Int, y: Int
        let left: Int, right: Int, top: Int, bottom: Int
    }
    struct Reference: Decodable { let boundingBoxes: [Case] }
    let url = try #require(
        Bundle.module.url(forResource: "terrain_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "terrain_reference", withExtension: "json"))
    let cases = try JSONDecoder().decode(Reference.self,
                                         from: Data(contentsOf: url)).boundingBoxes
    try #require(!cases.isEmpty)

    for c in cases {
        let box = TerrainPhases.box(around: UInt8(c.x), UInt8(c.y),
                                    radius: UInt8(c.radius))
        #expect(Int(box.left) == c.left && Int(box.right) == c.right
                    && Int(box.top) == c.top && Int(box.bottom) == c.bottom,
                """
                radius \(c.radius) at (\(c.x),\(c.y)): expected \
                \(c.left)...\(c.right) x \(c.top)...\(c.bottom), got \
                \(box.left)...\(box.right) x \(box.top)...\(box.bottom)
                """)
    }
}

/// `$28F1`, the scatter that runs before the marking.
///
/// Graded from the generator state the original actually had, because it carries
/// straight through from the land-mass phase and the band writer and a port cannot
/// derive it yet.
@Test("Scattering terrain around the islands matches the original")
func scatterMatchesOriginal() throws {
    let url = try #require(
        Bundle.module.url(forResource: "terrain_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "terrain_reference", withExtension: "json"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    let run = try LandMassStage.run(config: reference.config,
                                    seed: UInt16(reference.seed))

    let steps = try #require(reference.bands.first)
    let entry = steps[0], after = steps[1]
    #expect(after.phase == "afterScatter")

    var band = TerrainBand(landMask: run.mask, fromRow: 0)
    #expect(sha256(band.storage) == entry.sha256)

    var rng = WorldMakerRNG(seed: UInt16(entry.rng))
    TerrainPhases.scatterAroundIslands(run.islands, northern: true,
                                       in: &band, rng: &rng)
    if Int8(bitPattern: rng.next()) < 0 {
        TerrainPhases.placeStray(in: &band, rng: &rng, secondBand: false)
    }
    #expect(sha256(band.storage) == after.sha256,
            "the band after scattering differs from the original's")
}

/// The whole of `$2AE9`, against the band the next phase started from.
@Test("$2AE9 leaves the band the original left")
func islandPhaseMatchesOriginal() throws {
    let url = try #require(
        Bundle.module.url(forResource: "terrain_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "terrain_reference", withExtension: "json"))
    let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    let run = try LandMassStage.run(config: reference.config,
                                    seed: UInt16(reference.seed))

    let steps = try #require(reference.bands.first)
    var band = TerrainBand(landMask: run.mask, fromRow: 0)
    var rng = WorldMakerRNG(seed: UInt16(steps[0].rng))
    TerrainPhases.islands(run.islands, northern: true, in: &band, rng: &rng)

    let after = steps[2]
    #expect(after.phase == "spread")
    #expect(sha256(band.storage) == after.sha256,
            "the band after $2AE9 differs from the original's")
}


