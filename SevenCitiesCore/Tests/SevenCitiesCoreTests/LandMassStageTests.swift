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
        let landCells: Int
        let sites: [Site]
        let parameter: Int
        let islands: [Island]
        let lastColumn: Int
    }
    struct Island: Decodable {
        let column: Int
        let row: Int
        let southern: Bool
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

    let run = try LandMassStage.run(config: c.config, seed: UInt16(c.seed))
    #expect(run.stoppedBecause == nil, "\(label): \(run.stoppedBecause ?? "")")

    let actual = run.steps.map(describe)
    let expected = c.steps.map(describe)
    for i in 0..<min(expected.count, actual.count) where expected[i] != actual[i] {
        Issue.record("\(label) step \(i): expected \(expected[i]), got \(actual[i])")
        break
    }
    #expect(actual.count == expected.count,
            "\(label): expected \(expected.count) steps, got \(actual.count)")
    #expect(run.mask.landCells == c.landCells, "\(label): land cell count")
    #expect(sha256(run.mask.mapBytes) == c.maskSha256,
            "\(label): the finished mask differs from the original's")

    // $4500's sites. They touch no map data, but they draw from the same
    // generator, so getting them wrong is what puts the next command's landmasses
    // somewhere else.
    let sites = try #require(run.sites)
    let expectedSites = c.sites
    #expect(Int(sites.parameter) == c.parameter, "\(label): $EBCE parameter")
    // The second wave's islands, in the order the two tables hold them.
    let placed = run.islands.filter { !$0.southern } + run.islands.filter { $0.southern }
    #expect(placed.count == c.islands.count,
            "\(label): expected \(c.islands.count) islands, got \(placed.count)")
    for (i, want) in c.islands.enumerated() where i < placed.count {
        let got = placed[i]
        #expect(Int(got.column) == want.column && Int(got.row) == want.row
                    && got.southern == want.southern,
                """
                \(label) island \(i): expected (\(want.column),\(want.row))                 southern \(want.southern), got (\(got.column),\(got.row))                 southern \(got.southern)
                """)
    }

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




/// Writes the finished masks out as raw bitmaps so they can be looked at.
///
/// Diagnostic only, and off unless asked for: set `MASK_DUMP_DIR` to somewhere
/// outside the repo. The masks are generated map data.
///
///     MASK_DUMP_DIR=/tmp swift test --filter dumpMasks
@Test("diagnostic: dump finished masks",
      .enabled(if: ProcessInfo.processInfo.environment["MASK_DUMP_DIR"] != nil))
func dumpMasks() throws {
    let dir = ProcessInfo.processInfo.environment["MASK_DUMP_DIR"]!
    for seed: UInt16 in [0x1234, 0xBEEF, 0x0001] {
        for config in [0, 1, 2] {
            let run = try LandMassStage.run(config: config, seed: seed)
            let name = String(format: "mask_%04X_%d.bin", seed, config)
            try Data(run.mask.mapBytes).write(to: URL(fileURLWithPath: dir + "/" + name))
            print("  \(name): \(run.mask.landCells) land cells, \(run.islands.count) scattered islands")
        }
    }
}



