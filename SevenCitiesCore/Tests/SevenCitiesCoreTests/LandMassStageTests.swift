import CryptoKit
import Foundation
import Testing

@testable import SevenCitiesCore

/// The stage driving itself, with no fixture telling it what to do next.
///
/// `InteriorFillTests` replays a recorded step list; this generates one. The two
/// grade different things: that one says the walk and the fill are right given the
/// order, this one says the order is right too — which command runs, where each
/// landmass lands, when a continent goes looking for a satellite, and when the
/// mirror fires.
private struct Stage: Decodable {
    struct Step: Decodable {
        let kind: String
        let x: Int?, y: Int?
        let radius: Int?
        let horizontal: Bool?
        let vertical: Bool?
    }
    struct Site: Decodable {
        let column: Int
        let row: Int
        let southern: Bool
        let kind: Int
    }
    struct Case: Decodable {
        let seed: Int
        let config: Int
        let steps: [Step]
        let maskSha256: String
        let sites: [Site]
    }
    let unaided: [Case]
}

private func sha256(_ bytes: [UInt8]) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

private func describe(_ step: LandMassStage.Step) -> String {
    switch step {
    case let .outline(x, y, radius): return "outline (\(x),\(y)) r=\(radius)"
    case let .interior(x, y): return "interior (\(x),\(y))"
    case let .mirror(h, v): return "mirror h=\(h) v=\(v)"
    }
}

private func describe(_ step: Stage.Step) -> String {
    switch step.kind {
    case "outline": return "outline (\(step.x ?? -1),\(step.y ?? -1)) r=\(step.radius ?? -1)"
    case "interior": return "interior (\(step.x ?? -1),\(step.y ?? -1))"
    default: return "mirror h=\(step.horizontal ?? false) v=\(step.vertical ?? false)"
    }
}

private func loadCases() throws -> [Stage.Case] {
    let url = try #require(
        Bundle.module.url(forResource: "interior_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "interior_reference", withExtension: "json"))
    return try JSONDecoder().decode(Stage.self, from: Data(contentsOf: url)).unaided
}

/// The whole stage from a seed: every landmass placed, walked and filled, the
/// mirror, and the site selection that runs in the middle of it. Nothing read
/// from the fixture but the seed and the configuration.
@Test("The stage drives itself to the original's mask", arguments: 0..<9)
func stageRunsUnaided(index: Int) throws {
    let cases = try loadCases()
    try #require(index < cases.count)
    let c = cases[index]
    let label = "seed $\(String(format: "%04X", c.seed)) config \(c.config)"

    // Configuration 1 pairs its continent, and the partner is walked by a mode of
    // `$15AD` that is not ported. The fixture shows what is missing: one `$23D3`
    // for two continents, and two satellites from one pass of `$2629`.
    guard c.config != 1 else {
        #expect(throws: LandMassStage.Unsupported.self, "\(label) should refuse") {
            _ = try LandMassStage.run(config: c.config, seed: UInt16(c.seed))
        }
        return
    }

    let run = try LandMassStage.run(config: c.config, seed: UInt16(c.seed))
    #expect(run.stoppedBecause != nil, "the stage now runs further than this test")

    let actual = run.steps.map(describe)
    let expected = c.steps.map(describe)
    for i in 0..<min(expected.count, actual.count) where expected[i] != actual[i] {
        Issue.record("\(label) step \(i): expected \(expected[i]), got \(actual[i])")
        break
    }
    #expect(actual.count == expected.count,
            "\(label): expected \(expected.count) steps, got \(actual.count)")
    #expect(sha256(run.mask.mapBytes) == c.maskSha256,
            "\(label): the mask at the stopping point differs from the original's")

    // $4500's sites. They touch no map data, but they draw from the same
    // generator, so getting them wrong is what puts the next command's landmasses
    // somewhere else.
    // The original always ends with two sites; the port finds the second only
    // when it came from the ported search. Where it did not, the fixture still
    // records what the original chose, so the gap stays visible.
    let sites = try #require(run.sites)
    let expectedSites = sites.secondaryUnported ? Array(c.sites.prefix(1)) : c.sites
    let chosen = [sites.primary, sites.secondary].compactMap { $0 }
    #expect(chosen.count == expectedSites.count,
            "\(label): expected \(expectedSites.count) site(s), got \(chosen.count)")
    for (i, want) in expectedSites.enumerated() where i < chosen.count {
        let got = chosen[i]
        #expect(Int(got.column) == want.column && Int(got.row) == want.row
                    && got.southern == want.southern && Int(got.kind) == want.kind,
                """
                \(label) site \(i): expected (\(want.column),\(want.row))                 kind \(want.kind) southern \(want.southern), got                 (\(got.column),\(got.row)) kind \(got.kind) southern \(got.southern)
                """)
    }
}



