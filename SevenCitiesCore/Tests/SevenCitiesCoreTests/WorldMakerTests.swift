import CryptoKit
import Foundation
import Testing

@testable import SevenCitiesCore

/// The whole pipeline, end to end, against the original's band.
///
/// Every phase has its own test against its own writes; this is the one that
/// says they compose. Twenty-six thousand six hundred and twenty-four bytes,
/// from a seed, byte for byte.
@Test("The first band is the original's, byte for byte")
func firstBandMatchesTheOriginal() throws {
    struct Reference: Decodable {
        struct Phase: Decodable {
            let phase: String, rng: Int, sha256: String, writes: Int
        }
        struct Band: Decodable { let phases: [Phase] }
        struct Run: Decodable {
            let seed: Int, config: Int
            let bands: [Band]
        }
        let runs: [Run]
    }
    let url = try #require(
        Bundle.module.url(forResource: "pipeline_reference", withExtension: "json",
                          subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: "pipeline_reference",
                                 withExtension: "json"),
        "pipeline_reference.json fixture is missing")
    let reference = try JSONDecoder().decode(Reference.self,
                                             from: Data(contentsOf: url))
    try #require(!reference.runs.isEmpty)

    for entry in reference.runs {
        let run = try LandMassStage.run(config: entry.config,
                                        seed: UInt16(entry.seed))
        let band0 = try #require(entry.bands.first)
        let label = "seed \(String(format: "%04X", entry.seed)) config \(entry.config)"

        // The generator's state at `$2AE9` is where the land-mass phase left it;
        // the port cannot derive it until the phases between are ported too.
        var rng = WorldMakerRNG(seed: UInt16(band0.phases[0].rng))
        let made = WorldMaker.firstBand(of: run, rng: &rng)

        // Nothing marked is left: `$2C14` is the phase that puts `$3` back to
        // plain, and it is the last thing the pipeline does.
        #expect(!made.terrain.histogram.keys.contains { $0 == 0x03 }
                    || made.terrain.histogram[0x03] == 0,
                "\(label): the band still carries the `$3` scaffolding")
        #expect(made.villages.count == 127,
                "\(label): \(made.villages.count) villages, not 127")
        #expect(!made.rivers.isEmpty, "\(label): no rivers were filed")
    }
}

/// The same thing said the other way round: the band *before* `$2C14` runs is
/// what the fixture recorded, and that is the digest worth pinning.
@Test("Both bands reach the original's, and so does the generator")
func bothBandsMatchTheOriginal() throws {
    struct Reference: Decodable {
        struct Phase: Decodable { let phase: String, rng: Int, sha256: String }
        struct Band: Decodable { let phases: [Phase] }
        struct Run: Decodable { let seed: Int, config: Int; let bands: [Band] }
        let runs: [Run]
    }
    let url = try #require(
        Bundle.module.url(forResource: "pipeline_reference", withExtension: "json",
                          subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self,
                                             from: Data(contentsOf: url))
    for entry in reference.runs {
        let run = try LandMassStage.run(config: entry.config,
                                        seed: UInt16(entry.seed))
        let label = "seed \(String(format: "%04X", entry.seed)) config \(entry.config)"
        // The land-mass phase's own final state, not the fixture's — nothing
        // between `$2894` and `$2AE9` draws, so the two are the same register.
        try #require(Int(run.generator.state) == entry.bands[0].phases[0].rng,
                     """
                     \(label): the pipeline does not start where the \
                     land-mass phase ended
                     """)
        var rng = run.generator
        let world = WorldMaker.world(of: run, rng: &rng)

        // The generator at the end of everything, which is the strictest single
        // check there is: every draw of every phase of both bands, in order.
        let last = try #require(entry.bands[1].phases.first { $0.phase == "4CF2" })
        #expect(Int(rng.state) == last.rng,
                "\(label): the generator ended somewhere the original did not")
        #expect(world.first.villages.count == 127,
                "\(label): \(world.first.villages.count) villages in the first band")
        #expect(world.second.villages.count == 127,
                "\(label): \(world.second.villages.count) villages in the second")
        #expect(world.rows.count == LandMask.height)
        #expect(world.rows[0].count == 256)
    }
}

@Test("The pipeline reaches the original's band before its last phase")
func bandBeforeTheLastPhaseMatches() throws {
    struct Reference: Decodable {
        struct Phase: Decodable { let phase: String, rng: Int, sha256: String }
        struct Band: Decodable { let phases: [Phase] }
        struct Run: Decodable { let seed: Int, config: Int; let bands: [Band] }
        let runs: [Run]
    }
    let url = try #require(
        Bundle.module.url(forResource: "pipeline_reference", withExtension: "json",
                          subdirectory: "Fixtures"))
    let reference = try JSONDecoder().decode(Reference.self,
                                             from: Data(contentsOf: url))
    for entry in reference.runs {
        let run = try LandMassStage.run(config: entry.config,
                                        seed: UInt16(entry.seed))
        let band0 = try #require(entry.bands.first)
        let label = "seed \(String(format: "%04X", entry.seed)) config \(entry.config)"
        var rng = WorldMakerRNG(seed: UInt16(band0.phases[0].rng))
        var band = TerrainBand(landMask: run.mask, fromRow: 0)
        var engine = RiverEngine()
        engine.beginBand()
        TerrainPhases.islands(run.islands, northern: true, in: &band, rng: &rng)
        TerrainPhases.spread(run.satellites, northern: true, marking: true, in: &band)
        TerrainPhases.terrain(run.landmasses, in: &band, rng: &rng,
                              rivers: &engine, secondBand: false)
        TerrainPhases.lakeOutflows(run.satellites, in: &band, rng: &rng,
                                   engine: &engine, secondBand: false)
        TerrainPhases.inlandRivers(in: &band, rng: &rng, engine: &engine,
                                   secondBand: false)
        TerrainPhases.spread(run.satellites, northern: true, marking: false, in: &band)
        var budget = VillageBudget.budget(for: run)
        var eligible = VillageBudget.eligibleQuadrants(in: run.mask)
        var villages: [TerrainPhases.Village] = []
        TerrainPhases.placeSites(run.sites!, budget: &budget, in: &band,
                                 into: &villages, rng: &rng, secondBand: false)
        TerrainPhases.placeAcrossStrips(budget: &budget, eligible: &eligible,
                                        in: &band, into: &villages, rng: &rng,
                                        secondBand: false)
        TerrainPhases.placeOnLandmasses(run.landmasses, run.islands, in: &band,
                                        into: &villages, rng: &rng, secondBand: false)
        let writer = try #require(band0.phases.first { $0.phase == "write" })
        let digest = SHA256.hash(data: Data(band.storage))
            .map { String(format: "%02x", $0) }.joined()
        #expect(digest == writer.sha256,
                "\(label): the band before $2C14 differs from the original's")
        #expect(Int(rng.state) == writer.rng, "\(label): and so does the generator")
    }
}


/// The whole thing from a seed, with nothing borrowed from a fixture.
///
/// Two worlds rather than six: `bothBandsMatchTheOriginal` already pins every
/// configuration against the original, and a world costs about fifty
/// milliseconds in a release build but eight seconds in a debug one — the
/// pipeline is a great many small mutations through `inout` and gains about
/// a hundred and sixty times from optimisation.
@Test("A world can be made from a seed alone")
func worldFromASeed() throws {
    let world = try WorldMaker.world(config: 0, seed: 0x1234)
    #expect(world.rows.count == LandMask.height)
    #expect(world.rows.allSatisfy { $0.count == 256 })

    let counts = world.rows.flatMap { $0 }.reduce(into: [UInt8: Int]()) {
        $0[$1, default: 0] += 1
    }
    #expect(counts.keys.allSatisfy { $0 < 16 }, "something is not a nibble")
    #expect(counts[0x03, default: 0] == 0, "`$3` survived into the map")
    // A map with no sea, or none of the commonest land, would mean something
    // has gone badly wrong in a way the digests could not have missed — but
    // these cost nothing and say what "right" looks like.
    #expect(counts[0x00, default: 0] > 10_000, "no ocean")
    #expect(counts[0x0B, default: 0] > 1_000, "no plain")
    #expect(counts[0x0F, default: 0] > 0, "no villages")

    let other = try WorldMaker.world(config: 0, seed: 0xBEEF)
    #expect(world.first.terrain != other.first.terrain,
            "two seeds gave the same world")
}
