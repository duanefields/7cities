import Foundation
import Testing

@testable import SevenCitiesCore

/// Per-step decisions captured from the original 6502.
/// Regenerate with `tools/stepper_reference.py`.
private struct Reference: Decodable {
    struct Step: Decodable {
        let axis: String
        let rngHigh: UInt8, rngLow: UInt8
        let threshold: UInt8, axisSelect: UInt8
        let biasX: UInt8, biasY: UInt8, heading: UInt8
        let inX: UInt8, inY: UInt8
        let outX: UInt8, outY: UInt8
        let rngHighAfter: UInt8, rngLowAfter: UInt8
    }
    struct Case: Decodable {
        let label: String
        let steps: [Step]
    }
    let cases: [Case]
}

private func loadReference() throws -> Reference {
    let url = try #require(
        Bundle.module.url(forResource: "stepper_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "stepper_reference", withExtension: "json"),
        "stepper_reference.json fixture is missing")
    return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
}

private func state(_ s: Reference.Step) -> WalkerState {
    WalkerState(
        rng: WorldMakerRNG(high: s.rngHigh, low: s.rngLow),
        workingRadius: 0, centerX: 0, centerY: 0, shape: 0,
        offset: .init(dx: 0, dy: 0), candidate: .init(dx: 0, dy: 0),
        stepped: .init(dx: s.inX, dy: s.inY),
        heading: s.heading, step: 0,
        threshold: s.threshold, axis: s.axisSelect,
        biasX: s.biasX, biasY: s.biasY, drift: 0,
        span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0, radius: 0)
}

/// The coordinate the original reached, for every recorded step.
@Test("Steppers reach the same coordinate as the original")
func steppersMatchCoordinates() throws {
    let reference = try loadReference()
    var checked = 0
    for c in reference.cases {
        for (i, s) in c.steps.enumerated() {
            var w = state(s)
            CoastlineWalker.advance(&w, axis: s.axis == "x" ? .x : .y)
            checked += 1
            #expect(w.stepped.dx == s.outX && w.stepped.dy == s.outY, """
                \(c.label) step \(i) (\(s.axis)): heading \(s.heading), \
                threshold \(s.threshold), in (\(s.inX),\(s.inY)) — \
                expected (\(s.outX),\(s.outY)), got (\(w.stepped.dx),\(w.stepped.dy))
                """)
        }
    }
    #expect(checked > 100)
}

/// The generator state afterwards, which matters as much as the coordinate: a
/// stepper that lands correctly having consumed a different number of draws
/// desynchronizes every later step, and only the finished mask would show it.
@Test("Steppers consume exactly the draws the original consumed")
func steppersConsumeSameDraws() throws {
    let reference = try loadReference()
    for c in reference.cases {
        for (i, s) in c.steps.enumerated() {
            var w = state(s)
            CoastlineWalker.advance(&w, axis: s.axis == "x" ? .x : .y)
            #expect(w.rng.high == s.rngHighAfter && w.rng.low == s.rngLowAfter, """
                \(c.label) step \(i) (\(s.axis)): generator expected \
                $\(String(format: "%02X%02X", s.rngHighAfter, s.rngLowAfter)), got \
                $\(String(format: "%02X%02X", w.rng.high, w.rng.low))
                """)
        }
    }
}

/// Both outcomes must be present or the fixture proves nothing about the
/// threshold.
@Test("The stepper fixture exercises both stepping and holding")
func stepperFixtureDiscriminates() throws {
    let reference = try loadReference()
    let all = reference.cases.flatMap(\.steps)
    let moved = all.filter { ($0.outX, $0.outY) != ($0.inX, $0.inY) }.count
    #expect(moved > 0 && moved < all.count,
            "expected a mix of advanced and held steps, got \(moved) of \(all.count)")
}
