import Foundation
import Testing

@testable import SevenCitiesCore

/// Dumps the port's mask writes so they can be lined up against the original's.
///
/// Diagnostic only, and off unless asked for: set `WALKER_DUMP` to a fill's label
/// and `WALKER_DUMP_PATH` to somewhere outside the repo. The continent's full
/// sequence is 871 lines of generated map data, which is why this writes to a
/// path you choose rather than to a fixture.
///
///     WALKER_DUMP=continent WALKER_DUMP_PATH=/tmp/port.txt swift test --filter diagnostic
@Test("diagnostic: dump a fill's write sequence",
      .enabled(if: ProcessInfo.processInfo.environment["WALKER_DUMP"] != nil))
func dumpWriteSequence() throws {
    let label = ProcessInfo.processInfo.environment["WALKER_DUMP"] ?? "island"
    let url = try #require(
        Bundle.module.url(forResource: "walker_reference", withExtension: "json",
                          subdirectory: "Fixtures"))
    struct R: Decodable {
        struct C: Decodable { let label: String; let x: Int; let y: Int
                              let radius: Int; let zeroPage: [Int] }
        let cases: [C]
    }
    let r = try JSONDecoder().decode(R.self, from: Data(contentsOf: url))
    let c = try #require(r.cases.first { $0.label == label })
    let zp = c.zeroPage
    let usesSecond = c.radius < 10
    var s = WalkerState(
        rng: usesSecond
            ? WorldMakerRNG(high: UInt8(zp[0x1F]), low: UInt8(zp[0x20]))
            : WorldMakerRNG(high: UInt8(zp[0xCD]), low: UInt8(zp[0xCF])),
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
        plot: { x, y in log.append("P \(x),\(y)") },
        erase: { x, y in log.append("E \(x),\(y)") })

    let text = log.joined(separator: "\n") + "\n"
    if let path = ProcessInfo.processInfo.environment["WALKER_DUMP_PATH"] {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("  wrote \(log.count) writes to \(path)")
    } else {
        print(text)
    }
}
