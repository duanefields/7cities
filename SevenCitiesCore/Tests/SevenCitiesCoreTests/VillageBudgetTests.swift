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
    }
}
