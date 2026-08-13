import Foundation
import Testing

@testable import SevenCitiesCore

/// Prints the port's plot/erase sequence so it can be lined up against the
/// original's. Diagnostic only — enable when an outline diverges.
@Test("diagnostic: island plot and erase sequence", .disabled("diagnostic; enable when an outline diverges"))
func dumpIslandSequence() throws {
    let url = try #require(
        Bundle.module.url(forResource: "walker_reference", withExtension: "json",
                          subdirectory: "Fixtures"))
    struct R: Decodable {
        struct C: Decodable { let label: String; let x: Int; let y: Int
                              let radius: Int; let zeroPage: [Int] }
        let cases: [C]
    }
    let r = try JSONDecoder().decode(R.self, from: Data(contentsOf: url))
    let c = try #require(r.cases.first { $0.label == "island" })
    let zp = c.zeroPage
    var s = WalkerState(
        rng: WorldMakerRNG(high: UInt8(zp[0xCD]), low: UInt8(zp[0xCF])),
        workingRadius: UInt8(c.radius), centerX: UInt8(c.x),
        centerY: UInt16(c.y), shape: 0,
        offset: .init(dx: 0, dy: 0), candidate: .init(dx: 0, dy: 0),
        stepped: .init(dx: 0, dy: 0), heading: 0, step: 0xFF,
        threshold: 0, axis: 0, biasX: UInt8(zp[0xB1]), biasY: UInt8(zp[0xB2]),
        drift: UInt8(zp[0xB3]), span: 0, inverseSpan: 0, inverseSlack: 0,
        target: 0, third: 0, radius: UInt8(c.radius))
    CoastlineWalker.recomputeShape(&s)
    var mask = LandMask()
    var log: [String] = []
    _ = CoastlineWalker.traceOutline(&s, in: &mask,
        plot: { x, y in log.append("plot   (\(x),\(y))") },
        erase: { x, y in log.append("erase  (\(x),\(y))") })
    for (i, line) in log.enumerated() where i >= 70 && i < 100 {
        print("  \(i) \(line)")
    }
}
