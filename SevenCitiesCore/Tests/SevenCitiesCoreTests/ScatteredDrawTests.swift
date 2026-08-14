import Foundation
import Testing

@testable import SevenCitiesCore

/// `$0B16`, against every call the World Maker made in a whole run.
///
/// The routine is the mountain walkers' steering, and it is the first thing in
/// the pipeline that costs more than one register advance per call — twelve, one
/// per term of the sum. Two ports can agree on every value it returns and still
/// diverge, because one of them left the generator in the wrong place; so the
/// fixture records the register before and after as well as the result.
@Test("The scattered draw matches the original")
func scatteredDrawMatchesOriginal() throws {
    struct Reference: Decodable {
        struct Draw: Decodable {
            let mean: Int, spread: Int, rng: Int, value: Int, after: Int
        }
        let draws: [Draw]
    }
    let url = try #require(
        Bundle.module.url(forResource: "scatter_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "scatter_reference",
                                 withExtension: "json"),
        "scatter_reference.json fixture is missing")
    let draws = try JSONDecoder().decode(Reference.self,
                                         from: Data(contentsOf: url)).draws
    try #require(!draws.isEmpty)

    for (index, draw) in draws.enumerated() {
        var rng = WorldMakerRNG(seed: UInt16(draw.rng))
        let got = rng.nextScattered(around: UInt8(draw.mean),
                                    spread: UInt8(draw.spread))
        #expect(Int(got.value) == draw.value,
                """
                draw \(index): mean \(draw.mean) spread \(draw.spread) gave \
                \(got.value), not \(draw.value)
                """)
        let reached = String(format: "%04X", rng.state)
        let wanted = String(format: "%04X", draw.after)
        #expect(Int(rng.state) == draw.after,
                "draw \(index) left the generator at \(reached), not \(wanted)")
    }
}
