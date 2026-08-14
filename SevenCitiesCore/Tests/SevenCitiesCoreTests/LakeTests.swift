import CryptoKit
import Foundation
import Testing

@testable import SevenCitiesCore

/// `$3961` and `$3EAD`, the two water phases that follow the terrain.
///
/// Graded on writes for the same reason the ranges are: the phase is not
/// finished, and a band with part of it missing diverges from the original's
/// legitimately. `tools/pipeline_trace.py` tags each write with the river that
/// made it, so the part that *is* ported can be checked exactly — the lake's own
/// marsh and its outflow, which is the first river of the phase.
///
/// The whole phase is graded: the marsh `$3999` drops on each lake, the river
/// that flows out of it, and `$3B75`'s pass growing rivers back inland from the
/// mouths. Both what it wrote and where it left the generator, because the phase
/// after this one starts from that.
private struct PipelineReference: Decodable {
    struct Mark: Decodable { let mark: String; let writes: Int; let sha256: String }
    struct Phase: Decodable {
        let phase: String, rng: Int, sha256: String, writes: Int
        let marks: [Mark]
    }
    struct Band: Decodable { let phases: [Phase] }
    struct Run: Decodable {
        let seed: Int, config: Int
        let bands: [Band]
    }
    let runs: [Run]
}

private func digest(_ writes: ArraySlice<TerrainBand.Write>) -> String {
    let text = writes.map { "\($0.x),\($0.y),\($0.nibble)" }.joined(separator: "\n")
    return SHA256.hash(data: Data(text.utf8))
        .map { String(format: "%02x", $0) }.joined()
}

@Test("A lake's marsh and its outflow match the original")
func lakeOutflowMatchesOriginal() throws {
    let url = try #require(
        Bundle.module.url(forResource: "pipeline_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "pipeline_reference",
                                 withExtension: "json"),
        "pipeline_reference.json fixture is missing")
    let reference = try JSONDecoder().decode(PipelineReference.self,
                                             from: Data(contentsOf: url))
    let run = try #require(reference.runs.first { $0.config == 0 })
    let band0 = try #require(run.bands.first)
    let terrain = try #require(band0.phases.first { $0.phase == "terrain" })
    let lakes = try #require(band0.phases.first { $0.phase == "lakes" })

    let stage = try LandMassStage.run(config: run.config, seed: UInt16(run.seed))
    var band = TerrainBand(landMask: stage.mask, fromRow: 0)
    var rng = WorldMakerRNG(seed: UInt16(band0.phases[0].rng))
    var engine = RiverEngine()
    engine.beginBand()
    TerrainPhases.islands(stage.islands, northern: true, in: &band, rng: &rng)
    TerrainPhases.spread(stage.satellites, northern: true, marking: true, in: &band)
    try #require(Int(rng.state) == terrain.rng, "the phases before $2E32 disagree")

    TerrainPhases.terrain(stage.landmasses, in: &band, rng: &rng,
                          rivers: &engine, secondBand: false)
    // $2E32 is exact in both what it wrote and where it left the generator, and
    // the second of those is what makes anything after it gradeable at all.
    try #require(Int(rng.state) == lakes.rng,
                 "$2E32 left the generator somewhere the original did not")

    band.journal = []
    TerrainPhases.lakeOutflows(stage.satellites, in: &band, rng: &rng,
                               engine: &engine, secondBand: false)
    let journal = try #require(band.journal)

    #expect(journal.count == lakes.writes,
            "the phase wrote \(journal.count) cells, not \(lakes.writes)")
    var start = 0
    for mark in lakes.marks {
        let slice = journal[start..<min(start + mark.writes, journal.count)]
        start += mark.writes
        #expect(slice.count == mark.writes,
                "\(mark.mark): \(slice.count) writes, not \(mark.writes)")
        #expect(digest(slice) == mark.sha256,
                "\(mark.mark): the cells differ from the original's")
        if digest(slice) != mark.sha256 { break }
    }
    let rivers = try #require(band0.phases.first { $0.phase == "rivers" })
    #expect(Int(rng.state) == rivers.rng,
            "$3961 left the generator somewhere the original did not")

    // $3EAD is the same walker again with three things patched into it, so it
    // is graded here rather than in a file of its own.
    band.journal = []
    TerrainPhases.inlandRivers(in: &band, rng: &rng, engine: &engine,
                               secondBand: false)
    let inland = try #require(band.journal)
    #expect(inland.count == rivers.writes,
            "$3EAD wrote \(inland.count) cells, not \(rivers.writes)")
    start = 0
    for mark in rivers.marks {
        let slice = inland[start..<min(start + mark.writes, inland.count)]
        start += mark.writes
        #expect(slice.count == mark.writes,
                "\(mark.mark): \(slice.count) writes, not \(mark.writes)")
        #expect(digest(slice) == mark.sha256,
                "\(mark.mark): the cells differ from the original's")
        if digest(slice) != mark.sha256 { break }
    }
    let after = try #require(band0.phases.first { $0.phase == "unspread" })
    #expect(Int(rng.state) == after.rng,
            "$3EAD left the generator somewhere the original did not")
}
