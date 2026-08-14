import CryptoKit
import Foundation
import Testing

@testable import SevenCitiesCore

/// `$2ED2`'s mountain ranges, graded on what they wrote rather than on the band.
///
/// The band cannot be the test here. `$2E32` draws each landmass in four stages
/// and the last of them, `$380D`, is not ported — so from the first landmass
/// that reaches it onward the port's band and the original's are legitimately
/// different, and a digest of either says nothing useful. What *is* comparable
/// is the sequence of writes each stage makes, which `tools/range_trace.py`
/// records off the interpreter and ``TerrainBand/journal`` records off the port.
///
/// Which stages are reachable depends on the configuration, which is why the
/// fixture holds more than one. Configuration 0's first band reaches `$380D` on
/// its first landmass, so everything after that — including the small-landmass
/// drawer at `$2F0B` — is out of reach. Configuration 1's continent sits on the
/// last row of the band, which is too low for `$3134` and too short a spine for
/// `$380D`, so nothing in that band is unreachable and it grades end to end.
private struct RangeReference: Decodable {
    struct Stage: Decodable { let stage: String; let writes: Int; let sha256: String }
    struct Entry: Decodable {
        let radius: Int, x: Int, y: Int, writes: Int
        let stages: [Stage]
    }
    struct Band: Decodable {
        let islandsRng: Int, rng: Int
        let sweptSha256: String, sweptRng: Int
        let ranges: [Entry]
    }
    struct Run: Decodable {
        let seed: Int, config: Int
        let bands: [Band]
    }
    let runs: [Run]
}

/// The digest `tools/range_trace.py` takes, over the same text.
private func digest(_ writes: ArraySlice<TerrainBand.Write>) -> String {
    let text = writes.map { "\($0.x),\($0.y),\($0.nibble)" }.joined(separator: "\n")
    return SHA256.hash(data: Data(text.utf8))
        .map { String(format: "%02x", $0) }.joined()
}

private func hex(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

@Test("The mountain ranges write what the original wrote")
func rangesMatchOriginal() throws {
    let url = try #require(
        Bundle.module.url(forResource: "range_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "range_reference",
                                 withExtension: "json"),
        "range_reference.json fixture is missing")
    let reference = try JSONDecoder().decode(RangeReference.self,
                                             from: Data(contentsOf: url))
    try #require(!reference.runs.isEmpty)

    for run in reference.runs {
        // Only the first band. The second starts at row 192 with sixteen rows of
        // terrain the first band generated, and cannot be built until `$2C14` is.
        let reference = try #require(run.bands.first)
        let stage = try LandMassStage.run(config: run.config,
                                          seed: UInt16(run.seed))
        let label = "seed \(String(format: "%04X", run.seed)) config \(run.config)"

        var band = TerrainBand(landMask: stage.mask, fromRow: 0)
        var rng = WorldMakerRNG(seed: UInt16(reference.islandsRng))
        TerrainPhases.islands(stage.islands, northern: true, in: &band, rng: &rng)
        TerrainPhases.spread(stage.satellites, northern: true, marking: true,
                             in: &band)
        try #require(Int(rng.state) == reference.rng,
                     "\(label): the phases before $2E32 disagree")

        TerrainPhases.coastSweep(in: &band, rng: &rng, secondBand: false)
        TerrainPhases.shelfSweep(in: &band, secondBand: false)
        TerrainPhases.forestSweep(in: &band, rng: &rng, secondBand: false)
        try #require(hex(band.storage) == reference.sweptSha256,
                     "\(label): the sweeps disagree, so the ranges cannot mean anything")
        try #require(Int(rng.state) == reference.sweptRng, "\(label): sweep draws")

        band.journal = []
        let segments = TerrainPhases.ranges(stage.landmasses, in: &band, rng: &rng,
                                            secondBand: false)
        let journal = try #require(band.journal)

        // Everything up to the first stage the port does not have. After that
        // the original is working on a band the port has never seen.
        var expected: [RangeReference.Stage] = []
        var complete = true
        entries: for entry in reference.ranges {
            for stage in entry.stages where stage.stage == "sources" {
                complete = false
                break entries
            }
            expected += entry.stages
        }
        // A stage that wrote nothing does not appear in the fixture — the trace
        // tool only records stages that put a cell down — and the port marks
        // every stage it runs whether it drew or not. `$3134` skips a landmass
        // too near the bottom of the band, and that is the usual reason.
        var drawn: [(stage: TerrainPhases.Stage,
                     slice: ArraySlice<TerrainBand.Write>)] = []
        var start = 0
        for segment in segments {
            let slice = journal[start..<segment.end]
            start = segment.end
            if !slice.isEmpty { drawn.append((segment.stage, slice)) }
        }
        if complete {
            #expect(drawn.count == expected.count,
                    "\(label): the port drew \(drawn.count) stages, not \(expected.count)")
        }

        for (segment, want) in zip(drawn, expected) {
            let slice = segment.slice
            #expect(segment.stage.rawValue == want.stage,
                    "\(label): expected \(want.stage), got \(segment.stage.rawValue)")
            #expect(slice.count == want.writes,
                    "\(label) \(want.stage): \(slice.count) writes, not \(want.writes)")
            #expect(digest(slice) == want.sha256,
                    "\(label) \(want.stage): the cells differ from the original's")
            if slice.count != want.writes || digest(slice) != want.sha256 { break }
        }
    }
}
