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

    /// How far a world is from being finished, for a caller that wants to show
    /// it. Reported once per pipeline phase.
    ///
    /// Deliberately counted in *phases* rather than weighted by how long each
    /// takes. Measured in a debug build, a whole world is 1.2 to 2.2 seconds and
    /// the split between its stages swings hard — the second band came in at
    /// 131ms twice and 886ms once, out of the same three runs. Weights fitted to
    /// that would lurch and stall; a phase count moves unevenly in time but is
    /// never wrong about where the run actually is.
    public struct Progress: Sendable {
        /// Phases finished, from 1 to ``total``.
        public var step: Int
        public var total: Int
        /// What just finished, for a label beside the bar.
        public var label: String
        /// Which attempt this is, counting from 1. ``randomWorld()`` throws a
        /// stuck world away and builds another; when it does, `step` goes back
        /// to the beginning, and this is what says why.
        public var attempt: Int = 1
        public var fraction: Double { Double(step) / Double(total) }
    }

    public typealias ProgressHandler = @Sendable (Progress) -> Void

    /// The land-mass stage plus nine pipeline phases for each of the two bands.
    public static let progressSteps = 1 + phaseLabels.count * 2

    /// The nine phases of `$0E20`, in the order it calls them. `$2C14` clears
    /// the scaffolding marks and is folded into the last of them rather than
    /// given a step of its own, because it is four instructions.
    static let phaseLabels = [
        "Islands", "Water depth", "Terrain", "Lakes", "Rivers",
        "Coastlines", "Ancient cities", "Villages", "Outlying villages",
    ]

    /// Report phase `index` of a band, where the land-mass stage was step 1.
    private static func report(_ progress: ProgressHandler?, band: Int,
                               phase index: Int, attempt: Int) {
        guard let progress else { return }
        progress(Progress(step: 1 + band * phaseLabels.count + index + 1,
                          total: progressSteps,
                          label: "Band \(band + 1) of 2 — \(phaseLabels[index])",
                          attempt: attempt))
    }

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
        /// Which of the three worlds `$2146` chose.
        public var config = 0
        /// The seed this came from, when that means anything.
        ///
        /// `nil` for a stirred world, because a stirred world is not a function
        /// of its seed — the same sixteen bits give a different map every time,
        /// exactly as on hardware. See ``randomWorld()``.
        public var seed: UInt16?
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
                             drawLimit: Int = WorldMakerRNG.defaultLimit,
                             stirInterval: Int = 0,
                             progress: ProgressHandler? = nil,
                             attempt: Int = 1)
        throws -> World {
        let run = try LandMassStage.run(config: config, seed: seed,
                                        drawLimit: drawLimit,
                                        stirInterval: stirInterval)
        progress?(Progress(step: 1, total: progressSteps,
                           label: "Landmasses", attempt: attempt))
        var rng = run.generator
        rng.stirInterval = stirInterval
        let world = world(of: run, rng: &rng, progress: progress, attempt: attempt)
        guard !rng.isStuck else {
            throw WorldMakerRNG.Stuck(config: config, seed: seed,
                                      draws: rng.draws,
                                      reason: rng.stuckReason)
        }
        var stamped = world
        stamped.config = config
        stamped.seed = stirInterval > 0 ? nil : seed
        return stamped
    }

    /// A world the way the game makes one: seeded from the machine and stirred
    /// throughout.
    ///
    /// This is the honest entry point, and it takes no seed because on real
    /// hardware there is no such thing. `$20CB` reads the SID's oscillator twice
    /// for the register and `$2406` keeps feeding it noise on every raster
    /// interrupt, so a world is far more random than the sixteen bits it started
    /// from and no two are ever alike. ``world(config:seed:drawLimit:stirInterval:)``
    /// is the port's invention — a frozen register, so that a world can be
    /// reproduced and graded against the original.
    ///
    /// The difference is not academic. Frozen, about one `(seed, configuration)`
    /// pair in five contains a rejection sampler that can never be satisfied and
    /// no world comes out. Stirred, the sampler is handed new bits within a frame
    /// and walks out, which is why the original cannot hang and why this does not
    /// need a retry loop around it.
    ///
    /// The configuration is drawn the way `$2146` draws it, a byte over ninety.
    public static func randomWorld(progress: ProgressHandler? = nil) throws -> World {
        // Belt and braces. The two loops that hang have been repaired where they
        // hang, but "we found two" is not "there are two", and the watchdog can
        // only report a stall — it cannot know whether the map was nearly done.
        // Throwing away a world and building another costs about fifty
        // milliseconds and is invisible; there is nothing to preserve, because a
        // stopped run has no partial result worth keeping.
        var last: Error?
        for attempt in 1...8 {
            do {
                return try world(config: Int(UInt8.random(in: 0...255)) / 90,
                                 seed: UInt16.random(in: 1...UInt16.max),
                                 stirInterval: WorldMakerRNG.hardwareStirInterval,
                                 progress: progress, attempt: attempt)
            } catch {
                last = error
            }
        }
        throw last ?? WorldMakerRNG.Stuck(draws: 0)
    }

    /// `$0DB5` and `$0DC3`: the whole pipeline, both bands.
    ///
    /// `rng` starts where the land-mass phase left it — literally, since nothing
    /// between `$2894` and `$2AE9` draws.
    public static func world(of run: LandMassStage.Run,
                             rng: inout WorldMakerRNG,
                             progress: ProgressHandler? = nil,
                             attempt: Int = 1) -> World {
        let first = firstBand(of: run, rng: &rng, progress: progress,
                              attempt: attempt)
        // `$70`-`$73` are per band and the first one only spends from its own
        // half, so the second starts from a full count of its own.
        var eligible = VillageBudget.eligibleQuadrants(in: run.mask)
        let second = secondBand(of: run, after: first, eligible: &eligible,
                                rivers: first.rivers, rng: &rng,
                                progress: progress, attempt: attempt)
        return World(first: first, second: second, draws: rng.draws)
    }

    /// `$0E20` for the **first** band.
    ///
    /// Reproduces the original's 26,624 bytes exactly for seed `$1234` in all
    /// the configurations the fixtures cover, and leaves the generator where the
    /// original leaves it — which is what the second band will start from.
    public static func firstBand(of run: LandMassStage.Run,
                                 rng: inout WorldMakerRNG,
                                 progress: ProgressHandler? = nil,
                                 attempt: Int = 1) -> Band {
        var band = TerrainBand(landMask: run.mask, fromRow: 0)   // $0C9B
        var engine = RiverEngine()
        engine.beginBand()

        TerrainPhases.islands(run.islands, northern: true, in: &band, rng: &rng)
        report(progress, band: 0, phase: 0, attempt: attempt)
        TerrainPhases.spread(run.satellites, northern: true, marking: true,
                             in: &band)
        report(progress, band: 0, phase: 1, attempt: attempt)
        TerrainPhases.terrain(run.landmasses, in: &band, rng: &rng,
                              rivers: &engine, secondBand: false)
        report(progress, band: 0, phase: 2, attempt: attempt)
        TerrainPhases.lakeOutflows(run.satellites, in: &band, rng: &rng,
                                   engine: &engine, secondBand: false)
        report(progress, band: 0, phase: 3, attempt: attempt)
        TerrainPhases.inlandRivers(in: &band, rng: &rng, engine: &engine,
                                   secondBand: false)
        report(progress, band: 0, phase: 4, attempt: attempt)
        TerrainPhases.spread(run.satellites, northern: true, marking: false,
                             in: &band)
        report(progress, band: 0, phase: 5, attempt: attempt)

        var budget = VillageBudget.budget(for: run)
        var eligible = VillageBudget.eligibleQuadrants(in: run.mask)
        var villages: [TerrainPhases.Village] = []
        TerrainPhases.placeSites(run.sites!, budget: &budget, in: &band,
                                 into: &villages, rng: &rng, secondBand: false)
        report(progress, band: 0, phase: 6, attempt: attempt)
        TerrainPhases.placeAcrossStrips(budget: &budget, eligible: &eligible,
                                        in: &band, into: &villages, rng: &rng,
                                        secondBand: false)
        report(progress, band: 0, phase: 7, attempt: attempt)
        TerrainPhases.placeOnLandmasses(run.landmasses, run.islands, in: &band,
                                        into: &villages, rng: &rng,
                                        secondBand: false)

        // $4CF2 writes nothing to the band; measured over a whole run, in
        // either band. It is skipped rather than stubbed.
        TerrainPhases.clearMarks(in: &band)                      // $2C14
        report(progress, band: 0, phase: 8, attempt: attempt)

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
                                  rng: inout WorldMakerRNG,
                                  progress: ProgressHandler? = nil,
                                  attempt: Int = 1) -> Band {
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
        report(progress, band: 1, phase: 0, attempt: attempt)
        TerrainPhases.spread(run.satellites, northern: false, marking: true,
                             in: &band)
        report(progress, band: 1, phase: 1, attempt: attempt)
        TerrainPhases.terrain(run.landmasses, in: &band, rng: &rng,
                              rivers: &engine, secondBand: true)
        report(progress, band: 1, phase: 2, attempt: attempt)
        TerrainPhases.lakeOutflows(run.satellites, in: &band, rng: &rng,
                                   engine: &engine, secondBand: true)
        report(progress, band: 1, phase: 3, attempt: attempt)
        TerrainPhases.inlandRivers(in: &band, rng: &rng, engine: &engine,
                                   secondBand: true)
        report(progress, band: 1, phase: 4, attempt: attempt)
        TerrainPhases.spread(run.satellites, northern: false, marking: false,
                             in: &band)
        report(progress, band: 1, phase: 5, attempt: attempt)

        var budget = VillageBudget.budget(for: run)
        var villages: [TerrainPhases.Village] = []
        TerrainPhases.placeSites(run.sites!, budget: &budget, in: &band,
                                 into: &villages, rng: &rng, secondBand: true)
        report(progress, band: 1, phase: 6, attempt: attempt)
        TerrainPhases.placeAcrossStrips(budget: &budget, eligible: &eligible,
                                        in: &band, into: &villages, rng: &rng,
                                        secondBand: true)
        report(progress, band: 1, phase: 7, attempt: attempt)
        TerrainPhases.placeOnLandmasses(run.landmasses, run.islands, in: &band,
                                        into: &villages, rng: &rng,
                                        secondBand: true)
        TerrainPhases.clearMarks(in: &band)
        report(progress, band: 1, phase: 8, attempt: attempt)

        return Band(terrain: band, villages: villages,
                    rivers: engine.sources, mouths: engine.mouths,
                    patched: (engine.patchedPersistence, engine.patchedAllowance))
    }
}
