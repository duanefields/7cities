import Foundation
import Testing

@testable import SevenCitiesCore

/// What `$0C9B` counts off the finished mask, which is where the village phase
/// gets its budget from.
///
/// Worth its own test because the geometry was worked out from the counts rather
/// than from the listing — `$0C9B` shifts mask bytes out of its own instruction
/// stream and fills a rolling buffer, so it is very hard to read and very easy
/// to check. If a change ever moves these two numbers, the walk is wrong.
@Test("The mask's village-eligible quadrants match the original's count")
func eligibleQuadrantsMatchOriginal() throws {
    struct Reference: Decodable {
        struct Run: Decodable {
            let seed: Int, config: Int
            let quadrantsEvaluated: Int
            let northEligible: Int, southEligible: Int
            let villages: [Int], threshold: [Int]
            let islands: [Int], smallLandmasses: [Int]
            enum CodingKeys: String, CodingKey {
                case seed, config, quadrantsEvaluated, northEligible
                case southEligible, villages, threshold, islands
                case smallLandmasses
                case spread = "82"
                case firstVillages
            }
            let spread: [Int]
            let firstVillages: [[Int]]?
        }
        let runs: [Run]
    }
    let url = try #require(
        Bundle.module.url(forResource: "village_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "village_reference",
                                 withExtension: "json"),
        "village_reference.json fixture is missing")
    let reference = try JSONDecoder().decode(Reference.self,
                                             from: Data(contentsOf: url))
    try #require(!reference.runs.isEmpty)

    for run in reference.runs {
        let stage = try LandMassStage.run(config: run.config,
                                          seed: UInt16(run.seed))
        let counted = VillageBudget.eligibleQuadrants(in: stage.mask)
        let label = "seed \(String(format: "%04X", run.seed)) config \(run.config)"
        #expect(counted.north == run.northEligible,
                "\(label): \(counted.north) northern quadrants, not \(run.northEligible)")
        #expect(counted.south == run.southEligible,
                "\(label): \(counted.south) southern quadrants, not \(run.southEligible)")
        // Four hundred windows, four quadrants each — the same sixteen hundred
        // the interpreter evaluates.
        #expect(run.quadrantsEvaluated == 1600,
                "the original evaluated \(run.quadrantsEvaluated) quadrants, not 1600")

        // The two deductions come off the run itself rather than the fixture,
        // so the whole chain is the port's.
        let take = VillageBudget.deductions(from: stage)
        #expect([take.islands.north, take.islands.south] == run.islands,
                "\(label): island counts \(take.islands), not \(run.islands)")
        #expect([take.smallLandmasses.north, take.smallLandmasses.south]
                    == run.smallLandmasses,
                """
                \(label): small landmasses \(take.smallLandmasses), \
                not \(run.smallLandmasses)
                """)

        let budget = VillageBudget.budget(for: stage)
        #expect([Int(budget.villages.north), Int(budget.villages.south)]
                    == run.villages,
                "\(label): villages \(budget.villages), not \(run.villages)")
        #expect([Int(budget.threshold.north), Int(budget.threshold.south)]
                    == run.threshold,
                "\(label): threshold \(budget.threshold), not \(run.threshold)")
        #expect([Int(budget.spread.north), Int(budget.spread.south)] == run.spread,
                "\(label): spread \(budget.spread), not \(run.spread)")
    }
}

/// `$47E1` and `$4823`: the two sites the mirror chose, and the one thrown at
/// random after them.
///
/// The first three villages on the map, and the only part of `$47DF` ported so
/// far — `$486F`'s walk over the strips places the other hundred and twenty-odd.
@Test("The first villages go where the original put them")
func firstVillagesMatchOriginal() throws {
    struct Reference: Decodable {
        struct Run: Decodable {
            let seed: Int, config: Int
            let firstVillages: [[Int]]?
        }
        let runs: [Run]
    }
    struct Pipeline: Decodable {
        struct Phase: Decodable { let phase: String; let rng: Int }
        struct Band: Decodable { let phases: [Phase] }
        struct Run: Decodable { let seed: Int, config: Int; let bands: [Band] }
        let runs: [Run]
    }
    func load<T: Decodable>(_ name: String) throws -> T {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json",
                              subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    let reference: Reference = try load("village_reference")
    let pipeline: Pipeline = try load("pipeline_reference")

    for entry in reference.runs {
        guard let expected = entry.firstVillages, !expected.isEmpty else { continue }
        let run = try #require(pipeline.runs.first {
            $0.seed == entry.seed && $0.config == entry.config
        })
        let band0 = try #require(run.bands.first)
        let stage = try LandMassStage.run(config: run.config,
                                          seed: UInt16(run.seed))
        var band = TerrainBand(landMask: stage.mask, fromRow: 0)
        var rng = WorldMakerRNG(seed: UInt16(band0.phases[0].rng))
        var engine = RiverEngine()
        engine.beginBand()
        TerrainPhases.islands(stage.islands, northern: true, in: &band, rng: &rng)
        TerrainPhases.spread(stage.satellites, northern: true, marking: true,
                             in: &band)
        TerrainPhases.terrain(stage.landmasses, in: &band, rng: &rng,
                              rivers: &engine, secondBand: false)
        TerrainPhases.lakeOutflows(stage.satellites, in: &band, rng: &rng,
                                   engine: &engine, secondBand: false)
        TerrainPhases.inlandRivers(in: &band, rng: &rng, engine: &engine,
                                   secondBand: false)
        TerrainPhases.spread(stage.satellites, northern: true, marking: false,
                             in: &band)
        let villages = try #require(band0.phases.first { $0.phase == "villages" })
        try #require(Int(rng.state) == villages.rng,
                     "the phases before $47DF disagree")

        var budget = VillageBudget.budget(for: stage)
        var placed: [TerrainPhases.Village] = []
        TerrainPhases.placeSites(try #require(stage.sites), budget: &budget,
                                 in: &band, into: &placed, rng: &rng,
                                 secondBand: false)
        // The fixture holds column, row and kind; the port keeps half the row,
        // which is what `$40C8` files.
        let got = placed.map { [Int($0.column), Int($0.halfRow) * 2, Int($0.kind)] }
        #expect(got == Array(expected.prefix(got.count)),
                "the first villages are \(got), not \(expected.prefix(got.count))")
    }
}
