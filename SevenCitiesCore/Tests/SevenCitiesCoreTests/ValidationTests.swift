import Foundation
import Testing

@testable import SevenCitiesCore

/// Candidate tests captured from `$1A00` in the original.
/// Regenerate with `tools/validation_reference.py`.
private struct Reference: Decodable {
    struct Test: Decodable {
        let dx: Int, dy: Int, heading: Int
        let workingRadius: Int, workingRadiusAfter: Int
        let radius: Int, drift: Int
        let centerX: Int, centerY: Int
        let accepted: Bool
        let rejectedBy: String?
        /// Present only once the offset has been resolved, so absent whenever
        /// the circle test rejected before that point.
        let column: Int?, row: Int?
        let cells: [String: Int]?
    }
    struct Case: Decodable {
        let label: String
        let tests: [Test]
    }
    let cases: [Case]
}

private func loadReference() throws -> Reference {
    let url = try #require(
        Bundle.module.url(forResource: "validation_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "validation_reference", withExtension: "json"),
        "validation_reference.json fixture is missing")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
}

private func state(_ t: Reference.Test) -> WalkerState {
    WalkerState(
        rng: WorldMakerRNG(seed: 0), workingRadius: UInt8(t.workingRadius),
        centerX: UInt8(t.centerX), centerY: UInt16(t.centerY), shape: 0,
        offset: .init(dx: UInt8(t.dx), dy: UInt8(t.dy)),
        candidate: .init(dx: 0, dy: 0), stepped: .init(dx: 0, dy: 0),
        heading: UInt8(t.heading), step: 0,
        threshold: 0, axis: 0, biasX: 0, biasY: 0, drift: UInt8(t.drift),
        span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0,
        radius: UInt8(t.radius))
}

/// The circle test needs no mask, so it covers most of the fixture.
@Test("The circle test agrees with the original")
func circleTestMatchesOriginal() throws {
    let reference = try loadReference()
    var checked = 0
    for c in reference.cases {
        for (i, t) in c.tests.enumerated() {
            var w = state(t)
            let onCircle = CoastlineWalker.isOnCircle(&w)
            // A rejection at the circle stage means it must say no; anything
            // that got past it must say yes.
            let expected = t.rejectedBy != "circle"
            checked += 1
            #expect(onCircle == expected, """
                \(c.label) test \(i): offset (\(t.dx),\(t.dy)) heading \(t.heading), \
                working radius \(t.workingRadius) — expected \
                \(expected ? "on" : "off") the circle, got \(onCircle ? "on" : "off")
                """)
        }
    }
    #expect(checked > 50)
}

/// Radius modulation happens inside the test, so the value afterwards is part of
/// what has to match.
@Test("The circle test leaves the same working radius behind")
func circleTestModulatesIdentically() throws {
    let reference = try loadReference()
    for c in reference.cases {
        for (i, t) in c.tests.enumerated() {
            var w = state(t)
            _ = CoastlineWalker.isOnCircle(&w)
            #expect(Int(w.workingRadius) == t.workingRadiusAfter, """
                \(c.label) test \(i): working radius expected \
                \(t.workingRadiusAfter), got \(w.workingRadius)
                """)
        }
    }
}

/// The full test, for the cases that reached the clearance scan and therefore
/// carry the mask cells it read.
@Test("The clearance scan agrees with the original")
func clearanceScanMatchesOriginal() throws {
    let reference = try loadReference()
    var checked = 0
    for c in reference.cases {
        for (i, t) in c.tests.enumerated() {
            guard let cells = t.cells, let row = t.row else { continue }
            var mask = LandMask()
            for (key, set) in cells where set == 1 {
                mask.setLand(x: UInt8(Int(key)!), y: row)
            }
            var w = state(t)
            let clear = CoastlineWalker.isCandidateClear(&w, in: mask)
            checked += 1
            #expect(clear == t.accepted, """
                \(c.label) test \(i): column \(t.column ?? -1) row \(row) — \
                expected \(t.accepted ? "accept" : "reject"), got \
                \(clear ? "accept" : "reject")
                """)
        }
    }
    #expect(checked > 0, "no case reached the clearance scan")
}
