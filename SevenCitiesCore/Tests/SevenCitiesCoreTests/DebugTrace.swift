import Foundation
import Testing

@testable import SevenCitiesCore

@Test("debug: dump the satellite walk", .disabled("diagnostic only"))
func debugSatelliteWalk() throws {
    // Intentionally disabled; enable locally when the outline diverges.
}

/// Writes the port's range half of `$2E32` out for `tools/range_diff.py`.
///
/// A digest tells you the ranges are wrong; this tells you which write. Enable
/// it, run it, then run the differ against the `local/range_trace.json` that
/// `tools/range_trace.py` leaves behind. Disabled by default because it writes
/// outside the package.
@Test("debug: dump the port's range writes", .disabled("diagnostic only"))
func debugRangeWrites() throws {
    struct Reference: Decodable {
        struct Step: Decodable { let phase: String; let sha256: String; let rng: Int }
        let seed: Int, config: Int
        let bands: [[Step]]
        let terrainSweeps: [[Step]]
    }
    let url = try #require(
        Bundle.module.url(forResource: "terrain_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "terrain_reference",
                                 withExtension: "json"))
    let reference = try JSONDecoder().decode(Reference.self,
                                             from: Data(contentsOf: url))
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

    band.journal = []
    var rivers = RiverEngine()
    rivers.beginBand()
    let segments = TerrainPhases.ranges(run.landmasses, in: &band, rng: &rng,
                                        secondBand: false, rivers: &rivers)
    let journal = try #require(band.journal)

    var out: [[String: Any]] = []
    var start = 0
    for segment in segments {
        out.append(["stage": segment.stage.rawValue,
                    "writes": journal[start..<segment.end]
                        .map { [Int($0.x), $0.y, Int($0.nibble)] }])
        start = segment.end
    }
    // Three levels up from Tests/SevenCitiesCoreTests/ is the package, four the repo.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let path = root.appendingPathComponent("local/port_range_trace.json")
    try JSONSerialization.data(withJSONObject: out).write(to: path)
    print("wrote \(path.path): \(journal.count) writes in \(segments.count) stages")
}
