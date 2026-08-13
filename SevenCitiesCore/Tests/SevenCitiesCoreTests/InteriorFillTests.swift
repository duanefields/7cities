import CryptoKit
import Foundation
import Testing

@testable import SevenCitiesCore

/// The land-mass stage replayed step for step: every walk, every flood fill and
/// the mirror pass, in the order the original performed them, from an empty mask.
///
/// This is the rung above `OutlineTraceTests`. That one grades a single walk from
/// a recorded starting state; this one carries the mask forward, so a landmass
/// that trims itself against an earlier one has to get that right too, and it is
/// the only thing that exercises the interior fill at all.
///
/// What is *not* under test is placement. Each step's centre, radius and zero
/// page come from the fixture, because the placement loop is graded separately by
/// `landmass_reference.json`. What the fixture also supplies is the **order**,
/// which no per-landmass model would predict: six walks produce four fills,
/// because a continent's walk does not fill its own interior, and a mirror pass
/// lands in the middle. See `tools/interior_reference.py`, and NOTES.md for the
/// `$1666` branch that is still unported.
private struct Stage: Decodable {
    struct Step: Decodable {
        let index: Int
        let kind: String
        let x: Int?, y: Int?
        let maskBefore: String
        let writes: Int
        let writesSha256: String
        let radius: Int?
        let zeroPage: [Int]?
        let horizontal: Bool?
        let vertical: Bool?
    }
    let steps: [Step]
    let maskSha256: String
    let landCells: Int
}

private func sha256(_ bytes: some Sequence<UInt8>) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}

private func sha256(_ lines: [String]) -> String {
    sha256(Array(lines.joined(separator: "\n").utf8))
}

@Test("The land-mass stage builds every landmass exactly")
func landMassStageMatchesOriginal() throws {
    let url = try #require(
        Bundle.module.url(forResource: "interior_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "interior_reference", withExtension: "json"),
        "interior_reference.json fixture is missing")
    let stage = try JSONDecoder().decode(Stage.self, from: Data(contentsOf: url))

    // Diagnostic escape hatch: dump the mask this port has built by a given step
    // so it can be diffed against the original's. The mask is generated map data
    // and belongs outside the repo, hence the explicit path.
    //
    //     STAGE_DUMP=6 STAGE_DUMP_PATH=/tmp/port.bin swift test --filter landMassStage
    let dumpAt = ProcessInfo.processInfo.environment["STAGE_DUMP"].flatMap(Int.init)
    let dumpPath = ProcessInfo.processInfo.environment["STAGE_DUMP_PATH"]

    var mask = LandMask()
    for step in stage.steps {
        if step.index == dumpAt, let dumpPath {
            try Data(mask.mapBytes).write(to: URL(fileURLWithPath: dumpPath))
        }
        #expect(sha256(mask.mapBytes) == step.maskBefore,
                "step \(step.index) (\(step.kind)) started from the wrong mask")

        var writes: [String] = []
        switch step.kind {
        case "outline":
            let zp = try #require(step.zeroPage)
            let radius = try #require(step.radius)
            let x = try #require(step.x), y = try #require(step.y)
            // Satellites draw from $1F/$20, everything else from $CD/$CF — the
            // vector at $0B11 is swapped by $27D4. See NOTES.
            let usesSecond = radius < 10
            var s = WalkerState(
                rng: usesSecond
                    ? WorldMakerRNG(high: UInt8(zp[0x1F]), low: UInt8(zp[0x20]))
                    : WorldMakerRNG(high: UInt8(zp[0xCD]), low: UInt8(zp[0xCF])),
                workingRadius: UInt8(radius),
                centerX: UInt8(x), centerY: UInt16(y), shape: 0,
                offset: .init(dx: 0, dy: 0), candidate: .init(dx: 0, dy: 0),
                stepped: .init(dx: 0, dy: 0), heading: 0, step: 0xFF,
                threshold: 0, axis: 0,
                biasX: UInt8(zp[0xB1]), biasY: UInt8(zp[0xB2]), drift: UInt8(zp[0xB3]),
                span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0,
                radius: UInt8(radius))
            CoastlineWalker.recomputeShape(&s)
            _ = CoastlineWalker.traceOutline(&s, in: &mask,
                plot: { x, y in writes.append("P \(x),\(y)") },
                erase: { x, y in writes.append("E \(x),\(y)") })
        case "interior":
            let x = try #require(step.x), y = try #require(step.y)
            let outcome = InteriorFill.fill(column: UInt8(x), row: y, in: &mask,
                                            plot: { x, y in writes.append("P \(x),\(y)") })
            #expect(outcome == .filled, "step \(step.index) restarted the phase")
        case "mirror":
            // $1C89, reached from $4500 partway through the stage. Two coin
            // flips, and neither goes through the mask's own write path — which
            // is why a replay built only from the traced writes puts every
            // landmass after this step 60 rows and 89 columns out of place.
            if step.horizontal == true { mask.mirrorHorizontally() }
            if step.vertical == true { mask.flipVertically() }
        default:
            Issue.record("unknown step kind \(step.kind)")
        }

        #expect(writes.count == step.writes,
                "step \(step.index) (\(step.kind)): expected \(step.writes) writes, got \(writes.count)")
        #expect(sha256(writes) == step.writesSha256,
                "step \(step.index) (\(step.kind)): write sequence differs")
    }

    #expect(mask.landCells == stage.landCells)
    #expect(sha256(mask.mapBytes) == stage.maskSha256,
            "the finished mask differs from the original's")
}
