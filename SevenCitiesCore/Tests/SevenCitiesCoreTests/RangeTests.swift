import CryptoKit
import Foundation
import Testing

@testable import SevenCitiesCore

/// `$2ED2`'s mountain ranges, graded on what they wrote rather than on the band.
///
/// The band cannot be the test here. `$2E32` draws each landmass in four stages
/// and the last of them, `$380D`, is not ported — so from the first landmass
/// onward the port's band and the original's are legitimately different, and a
/// digest of either says nothing useful. What *is* comparable is the sequence of
/// writes each stage makes, which `tools/range_trace.py` records off the
/// interpreter and ``TerrainBand/journal`` records off the port.
///
/// So this grades the stages the port has, on the landmass they run on first,
/// and stops where the port does.
private struct RangeReference: Decodable {
    struct Stage: Decodable { let stage: String; let writes: Int; let sha256: String }
    struct Entry: Decodable {
        let radius: Int, x: Int, y: Int, writes: Int
        let stages: [Stage]
    }
    let bands: [[Entry]]
}

private struct TerrainReference: Decodable {
    struct Step: Decodable { let phase: String; let sha256: String; let rng: Int }
    let seed: Int, config: Int
    let bands: [[Step]]
    let terrainSweeps: [[Step]]
}

private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json"),
        "\(name).json fixture is missing")
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

/// The digest the trace tool takes, over the same text.
private func digest(_ writes: ArraySlice<TerrainBand.Write>) -> String {
    let text = writes.map { "\($0.x),\($0.y),\($0.nibble)" }.joined(separator: "\n")
    return SHA256.hash(data: Data(text.utf8))
        .map { String(format: "%02x", $0) }.joined()
}

/// The band the ranges start from: the mask, the two phases before `$2E32`, and
/// its three sweeps — all of which the tests either side of this one pin down.
private func bandBeforeRanges(_ reference: TerrainReference) throws
    -> (TerrainBand, WorldMakerRNG, LandMassStage.Run) {
    let run = try LandMassStage.run(config: reference.config,
                                    seed: UInt16(reference.seed))
    let steps = try #require(reference.bands.first)
    var band = TerrainBand(landMask: run.mask, fromRow: 0)
    var rng = WorldMakerRNG(seed: UInt16(steps[0].rng))
    TerrainPhases.islands(run.islands, northern: true, in: &band, rng: &rng)
    TerrainPhases.spread(run.satellites, northern: true, marking: true, in: &band)
    TerrainPhases.coastSweep(in: &band, rng: &rng, secondBand: false)
    TerrainPhases.shelfSweep(in: &band, secondBand: false)
    TerrainPhases.forestSweep(in: &band, rng: &rng, secondBand: false)

    let sweeps = try #require(reference.terrainSweeps.first)
    try #require(sha256Hex(band.storage) == sweeps[2].sha256,
                 "the sweeps disagree; the range test cannot mean anything")
    return (band, rng, run)
}

private func sha256Hex(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

@Test("The mountain ranges write what the original wrote")
func rangesMatchOriginal() throws {
    let terrain = try fixture("terrain_reference", as: TerrainReference.self)
    let ranges = try fixture("range_reference", as: RangeReference.self)

    var (band, rng, run) = try bandBeforeRanges(terrain)
    band.journal = []
    let segments = TerrainPhases.ranges(run.landmasses, in: &band, rng: &rng,
                                        secondBand: false)
    let journal = try #require(band.journal)

    // The first landmass in the band is the only one gradeable end to end: the
    // stage after the ones ported here changes the band, so everything drawn
    // afterward starts from somewhere the port has not been.
    let first = try #require(ranges.bands.first?.first)
    let ported = ["spine", "spur", "clearing"]
    var start = 0
    for segment in segments where ported.contains(segment.stage.rawValue) {
        let expected = first.stages.first { $0.stage == segment.stage.rawValue }
        let slice = journal[start..<segment.end]
        start = segment.end
        guard let expected else {
            #expect(slice.isEmpty,
                    """
                    \(segment.stage.rawValue) wrote \(slice.count) cells and \
                    the original never ran it
                    """)
            continue
        }
        #expect(slice.count == expected.writes,
                "\(segment.stage.rawValue): \(slice.count) writes, not \(expected.writes)")
        #expect(digest(slice) == expected.sha256,
                "\(segment.stage.rawValue): the cells differ from the original's")
        if slice.count != expected.writes || digest(slice) != expected.sha256 { break }
    }
}
