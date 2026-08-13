import Foundation
import Testing

@testable import SevenCitiesCore

/// Step evaluations captured from `$1476` in the original.
/// Regenerate with `tools/evaluator_reference.py`.
private struct Reference: Decodable {
    struct Evaluation: Decodable {
        let direction: Int, horizontalBase: Int, verticalBase: Int
        let dx: Int, dy: Int, heading: Int, edgeFlag: Int
        let workingRadius: Int, radius: Int, drift: Int
        let centerX: Int, centerY: Int
        let candidateDx: Int?, candidateDy: Int?
        let counters: [Int]?
        let scanColumn: Int?, scanRow: Int?
        let cells: [String: Int]?
        let accepted: Bool
        let rejectedBy: String?
    }
    struct Case: Decodable {
        let label: String
        let evaluations: [Evaluation]
    }
    let cases: [Case]
}

private func loadReference() throws -> Reference {
    let url = try #require(
        Bundle.module.url(forResource: "evaluator_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "evaluator_reference", withExtension: "json"),
        "evaluator_reference.json fixture is missing")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
}

private func state(_ e: Reference.Evaluation) -> WalkerState {
    WalkerState(
        rng: WorldMakerRNG(seed: 0), workingRadius: UInt8(e.workingRadius),
        centerX: UInt8(e.centerX), centerY: UInt16(e.centerY), shape: 0,
        offset: .init(dx: UInt8(e.dx), dy: UInt8(e.dy)),
        candidate: .init(dx: 0, dy: 0), stepped: .init(dx: 0, dy: 0),
        heading: UInt8(e.heading), step: 0,
        threshold: 0, axis: 0, biasX: 0, biasY: 0, drift: UInt8(e.drift),
        span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0,
        radius: UInt8(e.radius))
}

/// The candidate each of the nine directions proposes. This is where the 3x3
/// direction table is indexed twice with different bases, so an error rotates
/// the whole neighbourhood.
@Test("Proposed candidates match the original")
func proposedCandidatesMatchOriginal() throws {
    let reference = try loadReference()
    var checked = 0
    for c in reference.cases {
        for (i, e) in c.evaluations.enumerated() {
            guard let wantDx = e.candidateDx, let wantDy = e.candidateDy else { continue }
            var w = state(e)
            _ = CoastlineWalker.propose(&w, direction: UInt8(e.direction),
                                        horizontalBase: UInt8(e.horizontalBase),
                                        verticalBase: UInt8(e.verticalBase),
                                        edgeGuard: e.edgeFlag != 0)
            checked += 1
            #expect(Int(w.candidate.dx) == wantDx && Int(w.candidate.dy) == wantDy, """
                \(c.label) evaluation \(i): direction \(e.direction) \
                bases (\(e.horizontalBase),\(e.verticalBase)) from (\(e.dx),\(e.dy)) — \
                expected (\(wantDx),\(wantDy)), got (\(w.candidate.dx),\(w.candidate.dy))
                """)
        }
    }
    #expect(checked > 100)
}

/// The 3x3 land count the original accumulated into `$35`, from the origin the
/// original scanned. Separating the origin from the counting means a failure
/// says which of the two is wrong.
@Test("Neighbour counts match the original")
func neighborCountsMatchOriginal() throws {
    let reference = try loadReference()
    var checked = 0
    for c in reference.cases {
        for (i, e) in c.evaluations.enumerated() {
            guard let counters = e.counters, let cells = e.cells,
                  let dx = e.candidateDx, let dy = e.candidateDy else { continue }
            var mask = LandMask()
            for (key, set) in cells where set == 1 {
                let parts = key.split(separator: ",")
                mask.setLand(x: UInt8(Int(parts[0])!), y: Int(parts[1])!)
            }
            _ = dx; _ = dy
            let count = CoastlineWalker.neighborCount(
                fromColumn: UInt8(e.scanColumn!), row: e.scanRow!, in: mask)
            checked += 1
            #expect(count == counters.reduce(0, +), """
                \(c.label) evaluation \(i): column \(e.scanColumn ?? -1) \
                row \(e.scanRow ?? -1) — expected \(counters.reduce(0, +)) \
                land cells, got \(count)
                """)
        }
    }
    #expect(checked > 100)
}

/// Both outcomes present, or the fixture proves nothing about the verdict.
@Test("The evaluator fixture exercises both verdicts")
func evaluatorFixtureDiscriminates() throws {
    let reference = try loadReference()
    let all = reference.cases.flatMap(\.evaluations)
    let accepted = all.filter(\.accepted).count
    #expect(accepted > 0 && accepted < all.count,
            "expected a mix, got \(accepted) accepted of \(all.count)")
}


/// The scan origin, checked against where the original actually scanned. The
/// original decrements the column and row before building its pointer, so the
/// block surrounds the candidate rather than starting at it.
@Test("The scan origin sits one cell up and left of the candidate")
func scanOriginMatchesOriginal() throws {
    let reference = try loadReference()
    var checked = 0
    for c in reference.cases {
        for (i, e) in c.evaluations.enumerated() {
            guard let column = e.scanColumn, let row = e.scanRow,
                  let dx = e.candidateDx, let dy = e.candidateDy else { continue }
            var w = state(e)
            w.candidate = .init(dx: UInt8(dx), dy: UInt8(dy))
            let (cellColumn, cellRow) = CoastlineWalker.cell(
                offset: w.candidate, heading: w.heading,
                centerX: w.centerX, centerY: w.centerY)
            let origin = CoastlineWalker.scanOrigin(column: cellColumn, row: cellRow)
            checked += 1
            #expect(Int(origin.column) == column && origin.row == row, """
                \(c.label) evaluation \(i): candidate (\(dx),\(dy)) resolves to \
                (\(cellColumn),\(cellRow)); expected scan origin (\(column),\(row)), \
                got (\(origin.column),\(origin.row))
                """)
        }
    }
    #expect(checked > 100)
}
