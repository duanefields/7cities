/// The World Maker's pipeline, `$0E20`, end to end.
///
/// The land-mass phase leaves a 1-bit mask; this is everything that turns that
/// mask into map. It runs **once per band** — 208 rows of nibbles at a time, two
/// bands covering 400 rows with a sixteen-row overlap — and the nine phases run
/// in the order `$0E20` calls them.
///
/// The generator is threaded through all of it and never reseeded. That is not
/// incidental: half the phases are separated only by where they leave the
/// register, and a port that gets the cells right and the draws wrong will look
/// correct for one band and diverge on the next.
public enum WorldMaker {

    /// How many rows the two bands share — 416 rows of band across 400 of map.
    public static let overlap = TerrainBand.rows * 2 - LandMask.height

    /// What one band produces besides the band itself.
    public struct Band: Sendable {
        public var terrain: TerrainBand
        /// `$E800`: every village, with the map row halved.
        public var villages: [TerrainPhases.Village]
        /// `$E681`: both ends of every river.
        public var rivers: [RiverEngine.Source]
        /// `$E2F1`: the river mouths.
        public var mouths: [RiverEngine.Mouth]
        /// `$32FC` and `$33F0` as this band left them — two patched operands
        /// that carry into the next band. See ``RiverEngine/patchedPersistence``.
        public var patched: (persistence: UInt8, allowance: UInt8)
    }

    /// A finished world: the two bands, and the tables the game will want.
    public struct World: Sendable {
        public var first: Band
        public var second: Band
        /// How many times the generator was advanced to build it — the number
        /// the watchdog's ceiling is set against. See ``WorldMakerRNG/limit``.
        public var draws = 0
        /// The 400-row map, with the overlap taken from the second band — which
        /// is the copy the original leaves on the disk, since `$0F47` writes the
        /// second band over the sixteen rows the first one wrote there.
        public var rows: [[UInt8]] {
            var out: [[UInt8]] = []
            for row in 0..<LandMask.height {
                let source = row < TerrainBand.secondBandRow ? first : second
                let local = row < TerrainBand.secondBandRow
                    ? row : row - TerrainBand.secondBandRow
                out.append((0...255).map { source.terrain[UInt8($0), local] })
            }
            return out
        }
    }

    /// A whole world, from a seed and a configuration.
    ///
    /// The land-mass phase and then the pipeline, which is everything the World
    /// Maker does. Measured at about forty milliseconds in a release build, so
    /// there is no reason for a caller to cache one.
    ///
    /// Throws ``WorldMakerRNG/Stuck`` if the run blew `drawLimit`. That is the
    /// watchdog, and it is here rather than inside a phase because a stuck run
    /// has no partial result worth keeping: the loops give up where they stand
    /// and everything after them is drawn from a generator that is out of step.
    /// A caller that wants a world anyway should ask again with another seed.
    public static func world(config: Int, seed: UInt16,
                             drawLimit: Int = WorldMakerRNG.defaultLimit)
        throws -> World {
        let run = try LandMassStage.run(config: config, seed: seed,
                                        drawLimit: drawLimit)
        var rng = run.generator
        let world = world(of: run, rng: &rng)
        guard !rng.isStuck else {
            throw WorldMakerRNG.Stuck(config: config, seed: seed,
                                      draws: rng.draws)
        }
        return world
    }

    /// `$0DB5` and `$0DC3`: the whole pipeline, both bands.
    ///
    /// `rng` starts where the land-mass phase left it — literally, since nothing
    /// between `$2894` and `$2AE9` draws.
    public static func world(of run: LandMassStage.Run,
                             rng: inout WorldMakerRNG) -> World {
        let first = firstBand(of: run, rng: &rng)
        // `$70`-`$73` are per band and the first one only spends from its own
        // half, so the second starts from a full count of its own.
        var eligible = VillageBudget.eligibleQuadrants(in: run.mask)
        let second = secondBand(of: run, after: first, eligible: &eligible,
                                rivers: first.rivers, rng: &rng)
        return World(first: first, second: second, draws: rng.draws)
    }

    /// `$0E20` for the **first** band.
    ///
    /// Reproduces the original's 26,624 bytes exactly for seed `$1234` in all
    /// the configurations the fixtures cover, and leaves the generator where the
    /// original leaves it — which is what the second band will start from.
    public static func firstBand(of run: LandMassStage.Run,
                                 rng: inout WorldMakerRNG) -> Band {
        var band = TerrainBand(landMask: run.mask, fromRow: 0)   // $0C9B
        var engine = RiverEngine()
        engine.beginBand()

        TerrainPhases.islands(run.islands, northern: true, in: &band, rng: &rng)
        TerrainPhases.spread(run.satellites, northern: true, marking: true,
                             in: &band)
        TerrainPhases.terrain(run.landmasses, in: &band, rng: &rng,
                              rivers: &engine, secondBand: false)
        TerrainPhases.lakeOutflows(run.satellites, in: &band, rng: &rng,
                                   engine: &engine, secondBand: false)
        TerrainPhases.inlandRivers(in: &band, rng: &rng, engine: &engine,
                                   secondBand: false)
        TerrainPhases.spread(run.satellites, northern: true, marking: false,
                             in: &band)

        var budget = VillageBudget.budget(for: run)
        var eligible = VillageBudget.eligibleQuadrants(in: run.mask)
        var villages: [TerrainPhases.Village] = []
        TerrainPhases.placeSites(run.sites!, budget: &budget, in: &band,
                                 into: &villages, rng: &rng, secondBand: false)
        TerrainPhases.placeAcrossStrips(budget: &budget, eligible: &eligible,
                                        in: &band, into: &villages, rng: &rng,
                                        secondBand: false)
        TerrainPhases.placeOnLandmasses(run.landmasses, run.islands, in: &band,
                                        into: &villages, rng: &rng,
                                        secondBand: false)

        // $4CF2 writes nothing to the band; measured over a whole run, in
        // either band. It is skipped rather than stubbed.
        TerrainPhases.clearMarks(in: &band)                      // $2C14

        return Band(terrain: band, villages: villages,
                    rivers: engine.sources, mouths: engine.mouths,
                    patched: (engine.patchedPersistence, engine.patchedAllowance))
    }

    /// `$0E20` for the **second** band, which starts where the first one ended.
    ///
    /// The two bands go through the disk, and that is what decides what the
    /// second one starts from. `$0C9B` unpacks the whole four-hundred-row mask
    /// and writes it out as it goes; `$0F0C` reads a band back at the top of
    /// every `$0E20` and `$0F47` writes it out again at the bottom. So by the
    /// time the second band is read, the sixteen rows it shares with the first
    /// have already been overwritten by the first band's finished terrain — not
    /// the raw mask. Those sixteen rows are the seam the halves are stitched
    /// along, and nothing else in the port can produce them.
    ///
    /// What else carries across: the generator, untouched; the village count and
    /// the river-source index, which keep counting; and the eligible-quadrant
    /// counters, which the first band has already spent from. What does not: the
    /// mouth table, which `$3EBF` clears, and the survey threshold, which `$0E71`
    /// puts back to `$1A`.
    public static func secondBand(of run: LandMassStage.Run,
                                  after first: Band,
                                  eligible: inout (north: Int, south: Int),
                                  rivers: [RiverEngine.Source],
                                  rng: inout WorldMakerRNG) -> Band {
        var band = TerrainBand(landMask: run.mask,
                               fromRow: TerrainBand.secondBandRow)
        // $0F0C: the overlap comes back off the disk as the first band left it.
        for row in 0..<overlap {
            for column in 0...255 {
                band[UInt8(column), row] =
                    first.terrain[UInt8(column), TerrainBand.secondBandRow + row]
            }
        }

        var engine = RiverEngine()
        engine.sources = rivers                                  // $6B carries
        engine.patchedPersistence = first.patched.persistence    // $32FC
        engine.patchedAllowance = first.patched.allowance        // $33F0
        engine.beginBand()                                       // $0E40

        TerrainPhases.islands(run.islands, northern: false, in: &band, rng: &rng)
        TerrainPhases.spread(run.satellites, northern: false, marking: true,
                             in: &band)
        TerrainPhases.terrain(run.landmasses, in: &band, rng: &rng,
                              rivers: &engine, secondBand: true)
        TerrainPhases.lakeOutflows(run.satellites, in: &band, rng: &rng,
                                   engine: &engine, secondBand: true)
        TerrainPhases.inlandRivers(in: &band, rng: &rng, engine: &engine,
                                   secondBand: true)
        TerrainPhases.spread(run.satellites, northern: false, marking: false,
                             in: &band)

        var budget = VillageBudget.budget(for: run)
        var villages: [TerrainPhases.Village] = []
        TerrainPhases.placeSites(run.sites!, budget: &budget, in: &band,
                                 into: &villages, rng: &rng, secondBand: true)
        TerrainPhases.placeAcrossStrips(budget: &budget, eligible: &eligible,
                                        in: &band, into: &villages, rng: &rng,
                                        secondBand: true)
        TerrainPhases.placeOnLandmasses(run.landmasses, run.islands, in: &band,
                                        into: &villages, rng: &rng,
                                        secondBand: true)
        TerrainPhases.clearMarks(in: &band)

        return Band(terrain: band, villages: villages,
                    rivers: engine.sources, mouths: engine.mouths,
                    patched: (engine.patchedPersistence, engine.patchedAllowance))
    }
}
