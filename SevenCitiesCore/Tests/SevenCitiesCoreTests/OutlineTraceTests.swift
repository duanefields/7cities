import Foundation
import Testing

@testable import SevenCitiesCore

private struct Reference: Decodable {
    struct Event: Decodable {
        let kind: String
        let cellX: Int?, cellY: Int?
    }
    struct Case: Decodable {
        let label: String
        let x: Int, y: Int, radius: Int
        let zeroPage: [Int]
        let truncated: Bool
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

/// Rebuilds the walker's starting state from the zero page the original held at
/// `$23D3`, so the trace begins from exactly where the reference did.
private func state(_ c: Reference.Case) -> WalkerState {
    let zp = c.zeroPage
    // Satellites draw from $1F/$20, everything else from $CD/$CF — see NOTES.
    let usesSecond = c.radius < 10
    var s = WalkerState(
        rng: usesSecond
            ? WorldMakerRNG(high: UInt8(zp[0x1F]), low: UInt8(zp[0x20]))
            : WorldMakerRNG(high: UInt8(zp[0xCD]), low: UInt8(zp[0xCF])),
        workingRadius: UInt8(c.radius),
        centerX: UInt8(c.x), centerY: UInt16(c.y), shape: 0,
        offset: .init(dx: 0, dy: 0), candidate: .init(dx: 0, dy: 0),
        stepped: .init(dx: 0, dy: 0), heading: 0, step: 0xFF,
        threshold: 0, axis: 0,
        biasX: UInt8(zp[0xB1]), biasY: UInt8(zp[0xB2]), drift: UInt8(zp[0xB3]),
        span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0,
        radius: UInt8(c.radius))
    CoastlineWalker.recomputeShape(&s)
    return s
}

/// The first rung of the ladder: 23 plots, no backtracking, so a failure here is
/// in the walk itself rather than the undo ring.
@Test("The satellite outline matches the original")
func satelliteOutlineMatchesOriginal() throws {
    let reference = try loadReference()
    let c = try #require(reference.cases.first { $0.label == "satellite" })
    let expected = c.events.compactMap { e -> (Int, Int)? in
        guard e.kind == "plot", let x = e.cellX, let y = e.cellY else { return nil }
        return (x, y)
    }

    var s = state(c)
    var mask = LandMask()
    var drawn: [(Int, Int)] = []
    _ = CoastlineWalker.traceOutline(&s, in: &mask) { x, y in
        drawn.append((Int(x), y))
    }

    let common = min(drawn.count, expected.count)
    var firstDivergence: Int?
    for i in 0..<common where drawn[i] != expected[i] {
        firstDivergence = i
        break
    }
    #expect(firstDivergence == nil, {
        guard let i = firstDivergence else { return "" }
        return """
            satellite diverges at plot \(i): expected \
            (\(expected[i].0),\(expected[i].1)), got (\(drawn[i].0),\(drawn[i].1)). \
            Matched \(i) of \(expected.count) plots.
            """
    }())
    #expect(drawn.count == expected.count,
            "plot count: expected \(expected.count), got \(drawn.count)")
}
