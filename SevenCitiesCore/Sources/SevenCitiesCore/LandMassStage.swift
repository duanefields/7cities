/// The land-mass stage end to end — placing, walking, filling and mirroring.
///
/// ``LandMassPhase`` holds the placement arithmetic and ``CoastlineWalker`` holds
/// the walk; this is the loop that drives them, and it is where the order comes
/// from. The order is worth stating up front because nothing about it is
/// guessable from the routine names:
///
/// 1. `$2158` reads a command and runs it `count` times.
/// 2. Each landmass is placed by rejection sampling, then walked (`$23D3`).
/// 3. The walk's tail at `$1666` splits on the size class. **An island fills its
///    own interior and a continent does not.** A continent instead goes off and
///    places a *satellite* inside its own unfilled outline, walks that with
///    `$1666` patched to `RTS` so it cannot recurse, and only then floods —
///    from the continent's centre, filling both at once.
/// 4. `$44EF`, at the end of the first command only, mirrors the whole mask on
///    two coin flips and then picks the two sites — see ``SiteSelection``.
///
/// Transcribed from `$2158`, `$1666`, `$2629`, `$2794` and `$44EF`. What it
/// produces is checked against mask digests captured from the original under VICE
/// (`landmass_reference.json`) by way of `interior_reference.json`, which the
/// interpreter captured independently and which agrees with them on all nine
/// seed and configuration pairs.
public enum LandMassStage {

    /// One entry in a landmass position table (`$1B5F`).
    ///
    /// `$0300` holds the northern half and `$033C` the southern, each as
    /// `(row, column, radius)` triples — the southern one storing `row - 192` so
    /// it fits a byte. A continent tall enough to reach into both is filed
    /// **twice**, once in each, which is how a phase working on one band can see
    /// a landmass whose centre is in the other.
    public struct Landmass: Sendable, Equatable {
        public let column: UInt8
        public let row: UInt8
        public let radius: UInt8
        public let southern: Bool
    }

    /// One of the second wave's radius-3 islands (`$2867` and `$2874`).
    ///
    /// `southern` is which of the two tables it went into: `$03B4` for rows at or
    /// above 219, where the original stores `row - 192` to keep it in a byte, and
    /// `$038C` for the rest. What reads them has not been established.
    public struct Island: Sendable, Equatable {
        public let column: UInt8
        public let row: UInt16
        public let southern: Bool
    }

    /// Something that touched the mask, in the order it happened.
    ///
    /// Emitted so a port can be graded against the original's own sequence rather
    /// than only against the mask it ends with — a stage that does the right
    /// things in the wrong order still gets caught.
    public enum Step: Sendable, Equatable {
        case outline(x: UInt8, y: UInt16, radius: UInt8)
        case interior(x: UInt8, y: UInt16)
        case mirror(horizontal: Bool, vertical: Bool)
    }

    /// The scans in `$28AB` run off the end of a row, and `$1900`'s bounds check
    /// fails. Both reach `$2473`, which kills the raster interrupt and restarts
    /// the entire phase from `$20A3`. Thrown rather than looped, because a port
    /// that silently restarted would hide the fact that it happened.
    public struct Restart: Error, Sendable {}

    /// Configuration 1 pairs its continent, and the partner is built by a second
    /// mode of the walk (`$1860`, `$186C`, the `$50` flag) that is not ported.
    public struct Unsupported: Error, Sendable {
        public let reason: String
    }

    // MARK: - The satellite seed pool

    /// `$229B`-`$22AF`, the 21 bytes `$23F0` copies to `$0200`.
    ///
    /// Each is a high byte for the *second* generator; the satellite walk pairs it
    /// with a low byte of `$0C` and draws from `$1F`/`$20` instead of `$CD`/`$CF`.
    /// Not game data in any interesting sense — 21 constants that seed a random
    /// number generator.
    static let satelliteSeeds: [UInt8] = [
        0x77, 0xEC, 0xAA, 0xF1, 0x99, 0x54, 0xBA, 0x23, 0x30, 0xF9, 0x8E,
        0xE4, 0x68, 0x1F, 0x08, 0x64, 0xDC, 0x0E, 0x4D, 0xCA, 0x49,
    ]

    /// The value that marks a pool entry spent — and the low byte every seed is
    /// paired with, which is why a spent entry can be recognized by its value
    /// alone.
    static let spent: UInt8 = 0x0C

    /// The pool as `$0200` holds it during one continent's satellite placement.
    ///
    /// `$1666` writes `$0C` over entries 0, 1 and 20 of the table *before* copying,
    /// so three of the 21 start spent, and restores the table afterwards. The pool
    /// therefore does not carry over between continents: each one starts from the
    /// same 18.
    struct SeedPool {
        var entries: [UInt8]

        /// `$1666` spends entries 0, 1 and 20 before copying the table to
        /// `$0200` and restores them after, so a continent's search sees 18 and
        /// the second wave sees all 21.
        init(pristine: Bool = false) {
            entries = satelliteSeeds
            if !pristine { for index in [0, 1, 20] { entries[index] = spent } }
        }

        /// `$27BE`: draw an index, redraw while it lands on a spent entry, then
        /// spend it. `$27A9` refreshes the whole pool first if 20 or more are gone.
        mutating func take(_ rng: inout WorldMakerRNG) -> UInt8 {
            if entries.filter({ $0 == spent }).count >= 20 { self = SeedPool() }
            var index = Int(rng.nextModulo(21))
            while entries[index] == spent { index = Int(rng.nextModulo(21)) }
            let seed = entries[index]
            entries[index] = spent
            return seed
        }
    }

    // MARK: - The stage

    /// What one run of the stage produced.
    public struct Run: Sendable {
        public let mask: LandMask
        public let steps: [Step]
        /// The sites `$4500` chose partway through.
        public let sites: SiteSelection.Result?
        /// The second wave's islands, in the order they were placed. The original
        /// files them into two tables at `$038C` and `$03B4`, split by row.
        public let islands: [Island]
        /// The satellites — the lake-makers — in the order they were walked.
        /// `$1BF9` files them into `$0378` and `$0382`, split at row 215 rather
        /// than 219, and `$2D23` is what reads them back.
        public let satellites: [Island]
        /// Every landmass the command table placed, as `$1B5F` files them and
        /// `$1D42` fixes them up. `$2E32`'s mountain ranges read these back.
        public let landmasses: [Landmass]
        /// Why the stage stopped before the command table ran out. `nil` means it
        /// finished, which it now does for every configuration it accepts.
        public let stoppedBecause: String?
        /// Where the generator stands when the phase ends.
        ///
        /// This is also where `$0E20` starts. Measured across all three
        /// configurations: **nothing between `$2894` and `$2AE9` draws** — not
        /// the mask unpack at `$0C9B`, not `$40FA`'s arithmetic, not the setup at
        /// `$0DA0` — so the pipeline picks the register up exactly as the
        /// land-mass phase put it down.
        public let generator: WorldMakerRNG
    }

    /// Runs the command-table stage for one seed and configuration.
    ///
    /// All three configurations, to the end. `seed` is the generator's state at
    /// `$212A` — *after* `$2146` has drawn the configuration — which is why the
    /// two are separate arguments rather than one.
    public static func run(config: Int, seed: UInt16,
                           drawLimit: Int = WorldMakerRNG.defaultLimit) throws -> Run {
        var rng = WorldMakerRNG(seed: seed)
        rng.limit = drawLimit
        var mask = LandMask()
        var steps: [Step] = []
        var sites: SiteSelection.Result?
        var satellites: [Island] = []
        var landmasses: [Landmass] = []

        /// `$1B5F`: file a landmass into one table or the other, or both.
        func filed(column: UInt8, row: UInt16, radius: UInt8) -> [Landmass] {
            func north(_ value: UInt16) -> Landmass {
                Landmass(column: column, row: UInt8(truncatingIfNeeded: value),
                         radius: radius, southern: false)
            }
            func south(_ value: UInt16) -> Landmass {
                Landmass(column: column, row: UInt8(truncatingIfNeeded: value),
                         radius: radius, southern: true)
            }
            guard radius >= 0x46 else {
                // $1B65: anything small goes in one table or the other.
                return row < 0xC8 ? [north(row)] : [south(row &- 0xC0)]
            }
            // $1B75: a continent can straddle the two bands and is filed twice.
            if row < 0xC0 {
                let reach = UInt16(row) + 0x46
                return reach >= 0xCF ? [north(row), south(0)] : [north(row)]
            }
            var out = [south(row &- 0xC0)]
            // $1BAF: the northern entry for a continent reaching up out of the
            // southern band is filed at row `$C0` — the band boundary — not at
            // `row - radius`. `$23` is set to `$C0` for the call and put back
            // after.
            if row >= 0x46 && row &- 0x46 < 0xC0 { out.append(north(0xC0)) }
            return out
        }
        // `$0200`, the satellite seed pool. `$1666` rebuilds it for each
        // continent, but the second wave inherits whatever the last rebuild left
        // and spends from it across every island.
        var pool = SeedPool(pristine: true)
        // `$AB`, the guard that makes `$44EF` fire once and once only.
        var mirrored = false

        for command in LandMassPhase.configurations[config] {
            let radius = LandMassPhase.radius(continent: command.isContinent)

            for _ in 0..<command.count {
                // $2183: only $0F is wanted, and none of this draws.
                let motionLimit = UInt8((UInt16(radius) &* 5) / 7)

                // $2186 and $2193: both drawn before the code knows whether it
                // needs them, and both overwritten below. They still advance the
                // generator. See LandMassPhase.runCommandStage.
                var pairOffset: UInt8
                repeat {
                    pairOffset = rng.nextModulo(motionLimit) &+ 1
                } while pairOffset == 1
                let flip = rng.next()

                // $2193: the coin flip feeds $B1/$B2 for continents; $21A8
                // overrides it for anything smaller.
                var biasX: UInt8 = flip < 0x40 ? 0xFF : 0x40
                var biasY = biasX
                if radius < 0x46 {
                    biasX = 0xFF
                    biasY = 0x80
                }

                // $21B0: the offset only survives for a paired command.
                if !command.placesPair { pairOffset = 0xFF }
                let bounds = LandMassPhase.bounds(radius: radius,
                                                  paired: command.placesPair,
                                                  pairOffset: pairOffset,
                                                  config: config)

                // $221C: up to 256 attempts, the counter wrapping at $2281.
                var attempts = 0
                while attempts < 256 {
                    attempts += 1
                    let x = rng.nextByte(from: bounds.xLower, below: bounds.xUpper)
                    let y = rng.nextWord(from: bounds.yLower, below: bounds.yUpper)
                    guard LandMassPhase.isClear(x: x, y: y, radius: radius, in: mask)
                    else { continue }

                    // $2231: a paired command tests where the partner would go
                    // before accepting either, and then puts the first position
                    // back. Only one landmass is placed here — the second is
                    // grown by the walk itself, out of the isthmus at `$17C8`.
                    if command.placesPair {
                        let mate = LandMassPhase.partner(x: x, y: y, radius: radius,
                                                         pairOffset: pairOffset)
                        guard LandMassPhase.isClear(x: mate.x, y: mate.y,
                                                    radius: radius, in: mask)
                        else { continue }
                    }

                    let isthmus = try build(x: x, y: y, radius: radius,
                                            isContinent: command.isContinent,
                                            paired: command.placesPair,
                                            pairOffset: pairOffset,
                                            biasX: biasX, biasY: biasY,
                                            rng: &rng, mask: &mask, steps: &steps,
                                            filed: { satellites.append($0) })
                    // $2263 files the placement itself, and it comes *after*
                    // $1866's — the isthmus files as soon as its centre is
                    // known, which is in the middle of the walk.
                    landmasses += filed(column: x, row: y, radius: radius)
                    if let isthmus {
                        landmasses += filed(column: isthmus.column,
                                            row: isthmus.row, radius: radius)
                    }
                    break
                }
            }

            // $2277 JSR $44EF, guarded by $AB so only the first command's end
            // reaches the mirror at $1C89.
            if !mirrored {
                mirrored = true
                let horizontal = Int8(bitPattern: rng.next()) < 0
                if horizontal { mask.mirrorHorizontally() }
                let vertical = Int8(bitPattern: rng.next()) < 0
                if vertical { mask.flipVertically() }
                // $1D42: the mirror also rewrites the position tables, because
                // everything filed into them so far was filed in the old
                // coordinates. The second wave's islands are filed afterwards and
                // need no such thing, which is why they were right before this
                // was — and why a satellite marked a box of open sea.
                // $1D42: the position tables hold coordinates from before the
                // flip, so they are transformed too — column through `$1C2A` to
                // `256 - column`, row through `$1C3D` to `207 - row`. A vertical
                // flip also *swaps the two tables*, because a row mirrored inside
                // 208 rows belongs to the other band.
                //
                // Only what is already filed gets fixed up, which is why the
                // command table's islands come out untransformed: they are placed
                // by the second command, after this has run.
                func flip(_ column: UInt8, _ row: UInt8, _ southern: Bool)
                    -> (UInt8, UInt8, Bool) {
                    (horizontal ? UInt8(truncatingIfNeeded: 256 - Int(column)) : column,
                     vertical ? 0xCF &- row : row,
                     vertical ? !southern : southern)
                }
                if horizontal || vertical {
                    landmasses = landmasses.map { mass in
                        let (column, row, southern) = flip(mass.column, mass.row,
                                                           mass.southern)
                        return Landmass(column: column, row: row,
                                        radius: mass.radius, southern: southern)
                    }
                }
                // `256 - column`, the same as the landmass tables — not
                // `255 - column`. Measured across all three configurations:
                // configuration 0's northern satellite goes from column 106 to
                // 150, and 256 - 106 is 150. The one-off survived because the
                // only thing reading these before `$3961` was `$2D23`, whose
                // radius-10 box marks the same cells either way when the ring
                // around a lake is land.
                satellites = satellites.map { satellite in
                    let column = horizontal
                        ? UInt8(truncatingIfNeeded: 256 - Int(satellite.column))
                        : satellite.column
                    let row = vertical ? UInt16(LandMask.height - 1) &- satellite.row
                                       : satellite.row
                    return Island(column: column, row: row, southern: row >= 0xD7)
                }
                steps.append(.mirror(horizontal: horizontal, vertical: vertical))

                // $4500's second half, which is not land-mass work at all — but
                // it draws seven times from this generator with bounds taken from
                // the mask, so the rest of the command table depends on it.
                sites = try SiteSelection.choose(in: mask, rng: &rng)
            }
        }
        // $215F JMP $280A: the command table is exhausted, and the second wave
        // scatters small islands over whatever is left.
        let scattered = try secondWave(config: config, rng: &rng, mask: &mask,
                                       pool: &pool, steps: &steps)
        // The watchdog, reported where it happened rather than three phases
        // later: a stuck run leaves a mask nothing downstream should read.
        guard !rng.isStuck else {
            throw WorldMakerRNG.Stuck(config: config, seed: seed,
                                      draws: rng.draws)
        }
        return Run(mask: mask, steps: steps, sites: sites, islands: scattered,
                   satellites: satellites, landmasses: landmasses,
                   stoppedBecause: nil, generator: rng)
    }

    /// The second wave (`$280A`-`$2894`).
    ///
    /// A run of radius-3 islands, two to seven of them and eight to twelve in
    /// configuration 2, placed anywhere on the map that is clear rather than
    /// against any particular landmass. Each is drawn as a radius-10 candidate,
    /// retested at radius 5 and only then built at radius 3 — three radii for one
    /// island, which is how they end up well separated from everything.
    ///
    /// Rows 195 to 218 are refused outright, and the survivors are filed into one
    /// of two tables by the same boundary shifted up: below 219 into `$038C` as
    /// `(row, column)`, at or above into `$03B4` as `(row - 192, column)`. Both
    /// indices are halved at `$2894`, turning a byte offset into a count.
    ///
    /// It reuses the satellite path at `$2794`, so these islands draw from the
    /// second generator and from the same seed pool — which by now is pristine,
    /// `$167B` having restored it after the last continent, and which is **not**
    /// rebuilt between islands the way `$1666` rebuilds it between continents.
    private static func secondWave(config: Int, rng: inout WorldMakerRNG,
                                   mask: inout LandMask, pool: inout SeedPool,
                                   steps: inout [Step]) throws -> [Island] {
        // $280A: configuration 2 gets a lot more of them.
        let count = config == 2 ? rng.nextByte(from: 8, below: 13)
                                : rng.nextByte(from: 2, below: 8)
        // $2824: the placement window is the ordinary one for a radius-10
        // landmass — `$281F` patches `$222F` to `RTS` so `$21B8` computes the
        // bounds, draws, tests and returns rather than looping itself.
        let bounds = LandMassPhase.bounds(radius: 0x0A, paired: false,
                                          pairOffset: 0xFF, config: config)
        var islands: [Island] = []

        for _ in 0..<count {
            var attempts = 0
            while attempts < 256 {
                attempts += 1
                let x = rng.nextByte(from: bounds.xLower, below: bounds.xUpper)
                let y = rng.nextWord(from: bounds.yLower, below: bounds.yUpper)
                guard LandMassPhase.isClear(x: x, y: y, radius: 0x0A, in: mask)
                else { continue }
                // $2837: the excluded band, and only rows below 256 are tested.
                if y < 0x100 && y >= 0xC3 && y < 0xDB { continue }
                // $2845: a second, tighter clearance test.
                guard LandMassPhase.isClear(x: x, y: y, radius: 5, in: mask)
                else { continue }

                islands.append(Island(column: x, row: y, southern: y >= 0xDB))
                satelliteWalk(column: x, row: y, pool: &pool, rng: &rng,
                              mask: &mask, steps: &steps)
                steps.append(.interior(x: x, y: y))
                guard InteriorFill.fill(column: x, row: Int(y), in: &mask) == .filled
                else { throw Restart() }
                break
            }
        }
        return islands
    }

    /// One landmass: the walk, then whatever `$1666` decides comes next.
    private static func build(x: UInt8, y: UInt16, radius: UInt8,
                              isContinent: Bool, paired: Bool, pairOffset: UInt8,
                              biasX: UInt8, biasY: UInt8,
                              rng: inout WorldMakerRNG, mask: inout LandMask,
                              steps: inout [Step],
                              filed: @escaping (Island) -> Void)
        throws -> WalkerState.IsthmusLandmass? {
        let (partner, isthmus) = walk(x: x, y: y, radius: radius, biasX: biasX,
                                      biasY: biasY, drift: 0x97, paired: paired,
                                      pairOffset: pairOffset, rng: &rng,
                                      mask: &mask, steps: &steps)

        // $1666: `$54` is the command's size class. Islands go straight to the
        // flood fill; continents place a satellite first.
        if isContinent {
            var pool = SeedPool()
            try placeSatellite(centreX: x, centreY: y, rng: &rng, mask: &mask,
                               pool: &pool, steps: &steps, filed: filed)
            // $263D: a paired command runs `$2655` twice, the second time over
            // the geometry `$186C` filed away — so the continent grown out of the
            // isthmus gets a lake of its own.
            if paired, let partner {
                try placeSatellite(centreX: partner.centerX,
                                   centreY: partner.centerY, rng: &rng,
                                   mask: &mask, pool: &pool, steps: &steps,
                                   filed: filed)
            }
        }

        // $168D JMP $194A, from the landmass's own centre — which for a continent
        // is still water, because its interior has not been filled yet.
        steps.append(.interior(x: x, y: y))
        guard InteriorFill.fill(column: x, row: Int(y), in: &mask) == .filled
        else { throw Restart() }
        return isthmus
    }

    /// `$23D3`: set up the walker's state and trace an outline.
    ///
    /// `$217F` puts `$97` in the drift for a placed landmass; the satellite path
    /// leaves whatever is there, which is the same `$97` since nothing else writes
    /// it and `$17A6` returns early below radius `$46`.
    private static func walk(x: UInt8, y: UInt16, radius: UInt8,
                             biasX: UInt8, biasY: UInt8, drift: UInt8,
                             paired: Bool = false, pairOffset: UInt8 = 0xFF,
                             rng: inout WorldMakerRNG, mask: inout LandMask,
                             steps: inout [Step])
        -> (partner: WalkerState.Partner?,
            isthmus: WalkerState.IsthmusLandmass?) {
        var s = WalkerState(
            rng: rng, workingRadius: radius, centerX: x, centerY: y, shape: 0,
            offset: .init(dx: 0, dy: 0), candidate: .init(dx: 0, dy: 0),
            stepped: .init(dx: 0, dy: 0), heading: 0, step: 0xFF,
            threshold: 0, axis: 0, biasX: biasX, biasY: biasY, drift: drift,
            span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0,
            radius: radius)
        s.paired = paired
        s.pairOffset = pairOffset
        CoastlineWalker.recomputeShape(&s)
        steps.append(.outline(x: x, y: y, radius: radius))
        _ = CoastlineWalker.traceOutline(&s, in: &mask)
        rng = s.rng
        return (s.partnerGeometry, s.isthmusLandmass)
    }

    // MARK: - The satellite

    /// Places and walks the satellite that goes with a continent (`$2655`).
    ///
    /// It goes *inside* the continent, in the water its outline still encloses,
    /// which is the whole trick — and the trick is not what the name says.
    /// The flood fill that follows is seeded from the continent's centre and
    /// spreads through everything it can reach, which is everything except what
    /// this little ring encloses. The ring is land surrounded by land and
    /// disappears; its interior stays water. **This is the World Maker's inland
    /// lake generator**, and every continent gets exactly one, 20 to 43 cells.
    /// Measured across six generated worlds; see NOTES.md.
    private static func placeSatellite(centreX: UInt8, centreY: UInt16,
                                       rng: inout WorldMakerRNG,
                                       mask: inout LandMask, pool: inout SeedPool,
                                       steps: inout [Step],
                                       filed: @escaping (Island) -> Void) throws {
        // $2664: the window is the water between the coasts directly above and
        // below the centre, pulled in by two, and the search gives up after 70
        // rows either way.
        var lower = centreY                                     // $06/$03
        var upper = centreY                                     // $07/$53
        let ceiling = min(centreY &+ 0x46, 0x018E)              // $2675 clamp
        let floor = centreY >= 0x46 ? centreY &- 0x46 : 0       // $2688 clamp

        while !mask.isLand(x: centreX, y: Int(upper)) {          // $2696
            upper &+= 1
            if upper >= ceiling { break }
        }
        while !mask.isLand(x: centreX, y: Int(lower)) {          // $26C6
            if lower == 0 { break }
            lower &-= 1
            if lower < floor { break }
        }
        upper &-= 2                                              // $26EE
        lower &+= 2

        // $2710: up to 256 attempts at a spot.
        var attempts = 0
        while attempts < 256 {
            attempts += 1
            let row = rng.nextWord(from: lower, below: upper)
            // $2713: rows 185 to 214 are excluded outright.
            if row >= 0xB9 && row < 0xD7 { continue }

            let column = try columnWithin(row: row, near: centreX, rng: &rng,
                                          in: mask)
            guard LandMassPhase.isClear(x: column, y: row, radius: 0x10, in: mask)
            else { continue }

            // $2729: it has to be well away from the continent's centre on one
            // axis or the other — sixteen cells, either direction.
            let dx = column >= centreX ? column &- centreX : centreX &- column
            let dy = row >= centreY ? row &- centreY : centreY &- row
            guard dx >= 0x10 || dy >= 0x10 else { continue }

            // $2764: two more clearance tests at smaller radii before it commits.
            // Redundant-looking, and not redundant — `$22F7` samples a cross
            // rather than an area, so a smaller radius can fail where a larger
            // one passed.
            guard LandMassPhase.isClear(x: column, y: row, radius: 7, in: mask),
                  LandMassPhase.isClear(x: column, y: row, radius: 0x0C, in: mask)
            else { continue }

            // $2794: the satellite walks on the *second* generator, seeded from
            // the pool, with `$1666` patched to `RTS` so it neither recurses nor
            // floods. Its own interior is left to the continent's flood fill.
            satelliteWalk(column: column, row: row, pool: &pool, rng: &rng,
                          mask: &mask, steps: &steps, filed: filed)
            return
        }
    }

    /// Walks a radius-3 island (`$2794`).
    ///
    /// Both callers reach it the same way: `$1666` is patched to `RTS` first, so
    /// the walk traces an outline and stops — no recursion, and no flood fill of
    /// its own. Its randomness comes from `$1F`/`$20`, seeded with a byte taken
    /// from the pool and a low byte of `$0C`, which is why a satellite's shape is
    /// independent of everything the main generator has done.
    private static func satelliteWalk(column: UInt8, row: UInt16,
                                      pool: inout SeedPool,
                                      rng: inout WorldMakerRNG,
                                      mask: inout LandMask, steps: inout [Step],
                                      filed: ((Island) -> Void)? = nil) {
        // $1BF9: filed before the walk, and split at row 215 — not 219, which is
        // where the second wave's islands split. The two tables are neighbours in
        // memory and the boundaries are four rows apart.
        filed?(Island(column: column, row: row, southern: row >= 0xD7))
        var satellite = WorldMakerRNG(high: pool.take(&rng), low: spent)
        _ = walk(x: column, y: row, radius: 3, biasX: 0, biasY: 0, drift: 0x97,
                 rng: &satellite, mask: &mask, steps: &steps)
    }

    /// Picks a column inside the water span of a row (`$28AB`).
    ///
    /// Scans left and right from the continent's centre column for the first land
    /// each way, then draws between them. Running off either end of the row is not
    /// a miss — the original treats it as unrecoverable and restarts the phase.
    private static func columnWithin(row: UInt16, near centre: UInt8,
                                     rng: inout WorldMakerRNG,
                                     in mask: LandMask) throws -> UInt8 {
        var left = centre
        while !mask.isLand(x: left, y: Int(row)) {               // $28B6
            left &-= 1
            if left == 0 { throw Restart() }                     // $28C6 BNE
        }
        var right = centre
        while !mask.isLand(x: right, y: Int(row)) {              // $28CE
            right &+= 1
            if right == 0 { throw Restart() }                    // $28DE BNE
        }
        // $28E3: equal bounds means no room, and the left one is used as is.
        return left == right ? left : rng.nextByte(from: left, below: right)
    }
}
