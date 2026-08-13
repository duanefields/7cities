import Foundation
import Testing

@testable import SevenCitiesCore

/// One landmass fill from the original 6502, captured in the interpreter.
/// Regenerate with `tools/walker_reference.py`.
private struct Reference: Decodable {
    struct Event: Decodable {
        let kind: String
        let heading: Int, step: Int, workingRadius: Int
        /// Walk state, always present.
        let walkDx: Int, walkDy: Int
        /// The offset actually handed to `$13E0`, captured at the resolver
        /// itself. Absent on backtracks, which resolve nothing.
        let dx: Int?, dy: Int?
        /// The cell the **original** resolved that offset to, read from its own
        /// registers. Present on plots and erases.
        let cellX: Int?, cellY: Int?
    }
    struct Case: Decodable {
        let label: String
        let x: Int, y: Int, radius: Int
        let eventsTotal: Int, eventsRecorded: Int, truncated: Bool
        let events: [Event]
    }
    let cases: [Case]
}

private func loadReference() throws -> Reference {
    let url = try #require(
        Bundle.module.url(forResource: "walker_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "walker_reference", withExtension: "json"),
        "walker_reference.json fixture is missing")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
}

/// Every cell the original wrote, resolved from the offset and heading it held
/// at the time. This is what makes `$13E0` verifiable: the fixture records both
/// the offset and the cell the original computed from it, so a port that rotates
/// quadrants wrongly cannot agree with it.
@Test("Offset resolution matches every cell the original wrote")
func offsetResolutionMatchesOriginal() throws {
    let reference = try loadReference()
    #expect(!reference.cases.isEmpty)

    var checked = 0
    for c in reference.cases {
        for (index, e) in c.events.enumerated() {
            guard let wantX = e.cellX, let wantY = e.cellY,
                  let dx = e.dx, let dy = e.dy else { continue }
            let (x, y) = CoastlineWalker.cell(
                offset: .init(dx: UInt8(dx), dy: UInt8(dy)),
                heading: UInt8(e.heading),
                centerX: UInt8(c.x), centerY: UInt16(c.y))
            checked += 1
            #expect(Int(x) == wantX && y == wantY, """
                \(c.label) event \(index) (\(e.kind)): heading \(e.heading), \
                offset (\(dx),\(dy)) from centre (\(c.x),\(c.y)) — \
                expected cell (\(wantX),\(wantY)), got (\(x),\(y))
                """)
        }
    }
    #expect(checked > 200, "fixture should cover a few hundred resolutions")
}

/// The quadrant table is asymmetric — dx negates for headings 0 and 1, dy for 0
/// and 3 — which is not the pattern you would guess, so it is worth pinning
/// directly rather than only through the fixture.
@Test("The heading selects a quadrant by negating one or both components")
func headingSelectsQuadrant() {
    let offset = CoastlineWalker.Offset(dx: 10, dy: 20)
    let expected: [(x: Int, y: Int)] = [
        (90, 80),    // heading 0: -dx, -dy
        (90, 120),   // heading 1: -dx, +dy
        (110, 120),  // heading 2: +dx, +dy
        (110, 80),   // heading 3: +dx, -dy
    ]
    for (heading, want) in expected.enumerated() {
        let (x, y) = CoastlineWalker.cell(offset: offset, heading: UInt8(heading),
                                          centerX: 100, centerY: 100)
        #expect(Int(x) == want.x && y == want.y,
                "heading \(heading): expected (\(want.x),\(want.y)), got (\(x),\(y))")
    }
}

/// x is a byte and wraps; the original relies on that for landmasses near an
/// edge, so the port must not widen it.
@Test("Horizontal resolution wraps like a byte")
func horizontalWraps() {
    // Centre near the right edge, stepping further right.
    let (x, _) = CoastlineWalker.cell(offset: .init(dx: 10, dy: 0), heading: 2,
                                      centerX: 250, centerY: 100)
    #expect(x == 4, "250 + 10 should wrap to 4, not saturate")
}

/// The fixture must not quietly shrink: the ladder only localizes faults if the
/// small cases are whole and the truncated one says so.
@Test("The walker fixture covers the whole ladder")
func fixtureCoversTheLadder() throws {
    let reference = try loadReference()
    let labels = reference.cases.map(\.label)
    #expect(labels == ["satellite", "island", "continent"])

    let satellite = try #require(reference.cases.first { $0.label == "satellite" })
    #expect(!satellite.truncated, "the satellite case must be complete")
    #expect(satellite.events.allSatisfy { $0.kind == "plot" },
            "the satellite is the rung with no backtracking")

    let continent = try #require(reference.cases.first { $0.label == "continent" })
    #expect(continent.truncated && continent.eventsRecorded < continent.eventsTotal,
            "the continent case is a prefix and should declare it")
    #expect(continent.events.contains { $0.kind == "backtrack" },
            "the recorded prefix must still exercise backtracking")
}
