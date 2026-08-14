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

    /// What one band produces besides the band itself.
    public struct Band: Sendable {
        public var terrain: TerrainBand
        /// `$E800`: every village, with the map row halved.
        public var villages: [TerrainPhases.Village]
        /// `$E681`: both ends of every river.
        public var rivers: [RiverEngine.Source]
        /// `$E2F1`: the river mouths.
        public var mouths: [RiverEngine.Mouth]
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
                    rivers: engine.sources, mouths: engine.mouths)
    }
}
