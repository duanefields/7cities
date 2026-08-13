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
        /// Why the stage stopped before the command table ran out. `nil` means it
        /// finished, which it now does for every configuration it accepts.
        public let stoppedBecause: String?
    }

    /// Runs the command-table stage for one seed and configuration.
    ///
    /// Runs it to the end, for configurations 0 and 2. Configuration 1 throws:
    /// its command pairs the continent, and the partner is built by a mode of the
    /// walk that is not ported.
    public static func run(config: Int, seed: UInt16) throws -> Run {
        var rng = WorldMakerRNG(seed: seed)
        var mask = LandMask()
        var steps: [Step] = []
        var sites: SiteSelection.Result?
        // `$0200`, the satellite seed pool. `$1666` rebuilds it for each
        // continent, but the second wave inherits whatever the last rebuild left
        // and spends from it across every island.
        var pool = SeedPool(pristine: true)
        // `$AB`, the guard that makes `$44EF` fire once and once only.
        var mirrored = false

        for command in LandMassPhase.configurations[config] {
            if command.placesPair {
                throw Unsupported(reason: """
                    configuration \(config) pairs its continent, and the partner \
                    is built by the walk's $50 mode ($1860/$186C), which is not \
                    ported
                    """)
            }
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

                pairOffset = 0xFF                       // $21B4, unpaired only
                let bounds = LandMassPhase.bounds(radius: radius, paired: false,
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

                    try build(x: x, y: y, radius: radius,
                              isContinent: command.isContinent,
                              biasX: biasX, biasY: biasY,
                              rng: &rng, mask: &mask, steps: &steps)
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
        return Run(mask: mask, steps: steps, sites: sites, islands: scattered,
                   stoppedBecause: nil)
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
                              isContinent: Bool, biasX: UInt8, biasY: UInt8,
                              rng: inout WorldMakerRNG, mask: inout LandMask,
                              steps: inout [Step]) throws {
        walk(x: x, y: y, radius: radius, biasX: biasX, biasY: biasY,
             drift: 0x97, rng: &rng, mask: &mask, steps: &steps)

        // $1666: `$54` is the command's size class. Islands go straight to the
        // flood fill; continents place a satellite first.
        if isContinent {
            var pool = SeedPool()
            try placeSatellite(centreX: x, centreY: y, rng: &rng, mask: &mask,
                               pool: &pool, steps: &steps)
        }

        // $168D JMP $194A, from the landmass's own centre — which for a continent
        // is still water, because its interior has not been filled yet.
        steps.append(.interior(x: x, y: y))
        guard InteriorFill.fill(column: x, row: Int(y), in: &mask) == .filled
        else { throw Restart() }
    }

    /// `$23D3`: set up the walker's state and trace an outline.
    ///
    /// `$217F` puts `$97` in the drift for a placed landmass; the satellite path
    /// leaves whatever is there, which is the same `$97` since nothing else writes
    /// it and `$17A6` returns early below radius `$46`.
    private static func walk(x: UInt8, y: UInt16, radius: UInt8,
                             biasX: UInt8, biasY: UInt8, drift: UInt8,
                             rng: inout WorldMakerRNG, mask: inout LandMask,
                             steps: inout [Step]) {
        var s = WalkerState(
            rng: rng, workingRadius: radius, centerX: x, centerY: y, shape: 0,
            offset: .init(dx: 0, dy: 0), candidate: .init(dx: 0, dy: 0),
            stepped: .init(dx: 0, dy: 0), heading: 0, step: 0xFF,
            threshold: 0, axis: 0, biasX: biasX, biasY: biasY, drift: drift,
            span: 0, inverseSpan: 0, inverseSlack: 0, target: 0, third: 0,
            radius: radius)
        CoastlineWalker.recomputeShape(&s)
        steps.append(.outline(x: x, y: y, radius: radius))
        _ = CoastlineWalker.traceOutline(&s, in: &mask)
        rng = s.rng
    }

    // MARK: - The satellite

    /// Places and walks the satellite that goes with a continent (`$2655`).
    ///
    /// It goes *inside* the continent, in the water its outline still encloses,
    /// which is the whole trick: the flood fill that follows is seeded from the
    /// continent's centre and swallows both.
    private static func placeSatellite(centreX: UInt8, centreY: UInt16,
                                       rng: inout WorldMakerRNG,
                                       mask: inout LandMask, pool: inout SeedPool,
                                       steps: inout [Step]) throws {
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
                          mask: &mask, steps: &steps)
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
                                      mask: inout LandMask, steps: inout [Step]) {
        var satellite = WorldMakerRNG(high: pool.take(&rng), low: spent)
        walk(x: column, y: row, radius: 3, biasX: 0, biasY: 0, drift: 0x97,
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
