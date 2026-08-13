/// The coastline walker's mutable state, mirroring the original's zero page.
///
/// Named after what the bytes do rather than where they live, with the address
/// in a comment so the disassembly stays greppable. The grouping is not
/// cosmetic — see ``saved``, which the original relies on.
public struct WalkerState: Sendable {

    // MARK: - The saved block, `$1F`-`$25`
    //
    // `$1B55` copies `$47`-`$4D` into `$1F`-`$25` and `$17C8` copies back. These
    // seven bytes are what an unwind restores, and they include the generator.

    /// `$1F`/`$20` — the walker's own LFSR.
    ///
    /// **Not the same generator as the placement loop's.** `$0A9D` runs the
    /// identical algorithm to `$0AE2` on a different pair of bytes, and `$27D4`
    /// swaps `$0B11` between them so the same code draws from whichever is
    /// installed. Because this state lives in the saved block, **backtracking
    /// rewinds the randomness**: a retried step re-draws the same numbers rather
    /// than fresh ones, making an unwind a true undo. A port with one global
    /// generator diverges the first time a landmass backtracks, which is 155
    /// times in a single continent.
    public var rng: WorldMakerRNG
    /// `$21` — the working radius, recomputed every step by `$178A`.
    ///
    /// Distinct from the command's nominal radius, which stays in ``radius``.
    /// This one is modulated as the walk proceeds and is *the* mechanism that
    /// makes a coastline irregular rather than circular.
    public var workingRadius: UInt8
    /// `$22` — centre x. Fixed for the whole fill.
    public var centerX: UInt8
    /// `$23`/`$24` — centre y. Fixed for the whole fill.
    public var centerY: UInt16
    /// `$25` — a shape parameter from `$1731`.
    public var shape: UInt8

    // MARK: - Walk position

    /// `$14`/`$15` — the current offset from the centre.
    public var offset: CoastlineWalker.Offset
    /// `$16`/`$17` — the candidate offset being evaluated.
    public var candidate: CoastlineWalker.Offset
    /// `$44`/`$45` — the offset the steppers advance.
    public var stepped: CoastlineWalker.Offset
    /// `$1A` — the quadrant, 0...3. The walk turns when the axis coordinate for
    /// the current heading reaches zero.
    public var heading: UInt8
    /// `$46` — the step counter, indexing the undo ring and wrapping at 201.
    public var step: UInt8

    // MARK: - Per-step decision inputs

    /// `$18` — the step threshold, recomputed at `$2542` and again at `$2576`.
    ///
    /// Not a constant inherited from another phase, which an earlier reading of
    /// this code assumed: the writers are all outside `$14xx`-`$1Bxx`, but the
    /// walk reaches `$2542` through `$16B8 JMP $24FD`. The first value is the
    /// chosen coordinate scaled by ``inverseSpan``, so the further along an axis
    /// the walk has gone the less likely it is to step again — which is what
    /// bends a straight walk into an arc.
    public var threshold: UInt8
    /// `$19` — which axis the step advances: 0 for x, 1 for y.
    public var axis: UInt8
    /// `$B1`/`$B2` — direction bias, set per landmass.
    public var biasX: UInt8
    public var biasY: UInt8
    /// `$B3` — carried between fills and adjusted by `$17A6`.
    public var drift: UInt8

    // MARK: - Shape parameters from `$1731`

    /// `$0F` — `radius * 5 / 7`.
    public var span: UInt8
    /// `$10` — `$80 / span`, the scale applied to a coordinate to get a
    /// threshold.
    public var inverseSpan: UInt8
    /// `$11` — `$80 / (target - radius)`.
    public var inverseSlack: UInt8
    /// `$12` — roughly `radius * 1.44`, the target the distance metric aims at.
    public var target: UInt8
    /// `$13` — `radius * 3 / 8`.
    public var third: UInt8

    /// `$B0` — the command's nominal radius, constant for the fill.
    public var radius: UInt8

    /// The seven bytes an unwind restores (`$1F`-`$25`).
    ///
    /// Kept as one value so a port cannot restore the position and forget the
    /// generator, which is the failure this grouping exists to prevent.
    public struct Saved: Sendable {
        public var rng: WorldMakerRNG
        public var workingRadius: UInt8
        public var centerX: UInt8
        public var centerY: UInt16
        public var shape: UInt8
    }

    /// Captures the block `$1B55` would copy.
    public var saved: Saved {
        get { Saved(rng: rng, workingRadius: workingRadius, centerX: centerX,
                    centerY: centerY, shape: shape) }
        set {
            rng = newValue.rng
            workingRadius = newValue.workingRadius
            centerX = newValue.centerX
            centerY = newValue.centerY
            shape = newValue.shape
        }
    }
}
