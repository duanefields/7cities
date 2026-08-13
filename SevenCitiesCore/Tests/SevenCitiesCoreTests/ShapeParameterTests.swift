import Foundation
import Testing

@testable import SevenCitiesCore

/// The shape parameters the original had in zero page at each fill's entry,
/// read from `walker_reference.json`.
private struct Reference: Decodable {
    struct Case: Decodable {
        let label: String
        let radius: Int
        let zeroPage: [Int]
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

@Test("Shape parameters match the original for every landmass size")
func shapeParametersMatchOriginal() throws {
    let reference = try loadReference()
    for c in reference.cases {
        let zp = c.zeroPage
        var s = WalkerState(
            rng: WorldMakerRNG(seed: 0), workingRadius: UInt8(zp[0x21]),
            centerX: 0, centerY: 0, shape: 0,
            offset: .init(dx: 0, dy: 0), candidate: .init(dx: 0, dy: 0),
            stepped: .init(dx: 0, dy: 0), heading: 0, step: 0,
            threshold: 0, axis: 0, biasX: 0, biasY: 0, drift: 0,
            span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0,
            radius: UInt8(c.radius))
        CoastlineWalker.recomputeShape(&s)

        #expect(Int(s.span) == zp[0x0F], "\(c.label): $0F")
        #expect(Int(s.inverseSpan) == zp[0x10], "\(c.label): $10")
        #expect(Int(s.inverseSlack) == zp[0x11], "\(c.label): $11")
        #expect(Int(s.target) == zp[0x12], "\(c.label): $12")
        #expect(Int(s.third) == zp[0x13], "\(c.label): $13")
        #expect(Int(s.shape) == zp[0x25], "\(c.label): $25")
    }
}

/// Only continents modulate; islands and satellites hold a constant working
/// radius, which is what the traces show.
@Test("Radius modulation applies to continents only")
func modulationIsContinentsOnly() {
    for (radius, shouldMove) in [(UInt8(70), true), (UInt8(10), false), (UInt8(3), false)] {
        var s = WalkerState(
            rng: WorldMakerRNG(seed: 0x1234), workingRadius: radius,
            centerX: 0, centerY: 0, shape: 0,
            offset: .init(dx: 0, dy: 40), candidate: .init(dx: 0, dy: 0),
            stepped: .init(dx: 0, dy: 0), heading: 0, step: 0,
            threshold: 0, axis: 0, biasX: 0, biasY: 0, drift: 20,
            span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0,
            radius: radius)
        CoastlineWalker.modulateRadius(&s)
        #expect((s.workingRadius != radius) == shouldMove,
                "radius \(radius): expected working radius to \(shouldMove ? "change" : "hold")")
    }
}
