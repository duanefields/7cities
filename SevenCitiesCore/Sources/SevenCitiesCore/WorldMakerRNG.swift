/// The World Maker's pseudo-random number generator.
///
/// Transcribed from the original 6502 routine at `$0AE2` in `game3` (Ozark
/// Softscape, 1984). It is a 16-bit linear feedback shift register held in
/// zero page: `$CD` is the high byte, `$CF` the low byte. Each call shifts the
/// register eight times and returns the low byte.
///
/// The transcription is deliberately literal rather than simplified. `ROL` on
/// the 6502 is a *nine-bit* rotate through the carry flag, and the feedback
/// taps are read after four such rotates — reasoning that through algebraically
/// is easy to get subtly wrong, so the shape of the original is preserved.
///
/// The original additionally stirred `$CD` with live SID noise (`$D41B`) from
/// its raster interrupt handler, which made any particular world impossible to
/// reproduce even on real hardware. That stirring **is** reproduced here, and it
/// is optional: see ``stirInterval``. Off, a seed yields one fixed world and the
/// port can be graded against the original; on, the World Maker behaves like the
/// game, where a world is far more random than the sixteen bits it started from.
public struct WorldMakerRNG: Sendable {

    /// High byte of the shift register (`$CD` in the original).
    public private(set) var high: UInt8

    /// Low byte of the shift register (`$CF` in the original).
    public private(set) var low: UInt8

    /// The current register state as a single 16-bit value.
    public var state: UInt16 { UInt16(high) << 8 | UInt16(low) }

    /// How many times the register has been advanced.
    ///
    /// This is the watchdog, and it lives here because most of what can hang the
    /// World Maker is a rejection sampler: `$0FF8` redraws until its throw lands
    /// on land, `$22B4` redraws until the byte is in range, `$4373` until an
    /// even row falls inside a band, `$4A37` until a village fits. One counter
    /// on the generator sees every one of them, including any nobody has
    /// enumerated, because none of them can spin without drawing.
    ///
    /// **It does not see everything.** A handful of scans step a *wrapping*
    /// column with nothing to stop them and take no draw at all — `$194E`,
    /// `$1961`, `$17F2`, `$3268`, `$369F`, `$4021` — and `$16D1`'s unwind can
    /// walk the undo ring forever without drawing either. Those bound themselves
    /// and report through ``declareStuck()``. Counting draws was the first
    /// design and it was not enough on its own; that is worth knowing before
    /// anyone simplifies this back down to one mechanism.
    public private(set) var draws = 0

    /// The number of draws past which the run is declared stuck.
    ///
    /// A ceiling, not a schedule. It sits far enough above the worst real world
    /// that no terminating seed can reach it, so it cannot change what any seed
    /// generates — it only decides how long a run that is going nowhere may take
    /// before somebody notices. See ``defaultLimit`` and ``Stuck``.
    public var limit = WorldMakerRNG.defaultLimit

    /// The default ceiling: nearly four times the worst world in the input space.
    ///
    /// Swept over every seed from 1 to 65,535 in all three configurations, the
    /// most expensive world that *finishes* costs 13,175,820 draws — seed
    /// `$5D28`, configuration 1 — against a median in the low millions. A
    /// ceiling a legitimate world could reach would not be a watchdog; it would
    /// be part of what a seed generates, so this one is set clear of the tail
    /// rather than snugly above it.
    ///
    /// **Where the number stops mattering.** In practice this is not the
    /// mechanism that fires. Run over 6,900 worlds with the ceiling at two
    /// billion — off, for all purposes — the outcome is identical to running
    /// them at twenty million, down to the same worst draw count and the same
    /// failures: every run that does not finish is stopped first by a loop that
    /// bounds itself and calls ``declareStuck()``. Not one world was rescued by
    /// the extra room. What the extra room *does* cost is time, since a run that
    /// is going nowhere spends the whole budget before anything notices — two
    /// billion took eight times as long to give up as twenty million did.
    ///
    /// So this sits between the two: margin enough that no world yet measured
    /// could reach it, and small enough that giving up takes about a second.
    /// This counter is the net for the sampler nobody has enumerated.
    public static let defaultLimit = 50_000_000

    /// Thrown when a run draws past its ``limit``.
    ///
    /// It means a rejection sampler found no acceptable candidate and would have
    /// gone on asking forever — a hang, not a bad map. There is no partial result
    /// worth keeping, so the whole world is discarded.
    ///
    /// **This cannot happen on a C64.** `$2406`, in the raster IRQ, adds live SID
    /// noise to `$CD` on every interrupt, so a sampler with no answer from the
    /// current register gets fresh entropy within a frame and walks out. The port
    /// drops that stir so a seed reproduces, which is what turns "asks again with
    /// new bits" into "asks the same question for ever". Roughly one (seed,
    /// configuration) pair in five has no *deterministic* world; every one of them
    /// builds a map on hardware. See NOTES.md.
    public struct Stuck: Error, CustomStringConvertible, Sendable {
        /// Which world it was, where the caller knew — the entry point does,
        /// a routine deep inside a phase does not.
        public var config: Int?
        public var seed: UInt16?
        public var draws: Int
        /// Which self-bounding loop gave up, or `nil` when the draw ceiling was
        /// what stopped it.
        public var reason: String?

        public init(config: Int? = nil, seed: UInt16? = nil, draws: Int,
                    reason: String? = nil) {
            self.config = config
            self.seed = seed
            self.draws = draws
            self.reason = reason
        }

        public var description: String {
            let which = seed.map {
                " on seed \(String(format: "$%04X", $0))"
                    + (config.map { " configuration \($0)" } ?? "")
            } ?? ""
            return "the World Maker got stuck\(which) after \(draws) draws"
        }
    }

    /// Whether this run has drawn past its ``limit``, or been declared stuck.
    ///
    /// Every unbounded loop in the pipeline tests this and gives up when it is
    /// true. The values they leave behind are garbage; the caller that set the
    /// limit is expected to throw the whole world away rather than use it.
    public var isStuck: Bool { declaredStuck || draws > limit }

    private var declaredStuck = false

    /// Declare the run stuck without waiting for the draw count to say so.
    ///
    /// For the loops ``draws`` cannot see. Each of them bounds itself at the
    /// point where it would be repeating work it has already done — one lap of a
    /// wrapping column, one pass of the undo ring — and then says so here, so
    /// that a world it spoiled is discarded rather than quietly handed back a
    /// shape short. A bound reached is not a result; it is a hang caught.
    public mutating func declareStuck(_ reason: StaticString = #function) {
        declaredStuck = true
        if stuckReason == nil { stuckReason = "\(reason)" }
    }

    /// Which self-bounding loop gave up, when one did. Diagnostic only — the
    /// draw ceiling leaves this `nil`.
    public private(set) var stuckReason: String?

    // MARK: - The stir

    /// How many draws apart the raster interrupt lands, or 0 for a frozen
    /// register.
    ///
    /// `$2406`, inside the IRQ handler at `$23FC`, is
    /// `LDA $D41B / ADC $CD / STA $CD`: a byte of live SID oscillator noise
    /// added into the register's **high byte, on every interrupt**. It is why no
    /// two worlds were ever alike on real hardware, and — much less obviously —
    /// why the original cannot hang. A rejection sampler with no answer from the
    /// current register does not sit there asking; within a frame it has been
    /// handed new bits and it walks out.
    ///
    /// Zero is the *port's* invention, not the game's. It makes a world a pure
    /// function of `(seed, config)`, which is the only reason any of this could
    /// be checked against the original at all — `tools/wm_deterministic.py` NOPs
    /// exactly this instruction to capture the fixtures. It also costs: with the
    /// register frozen, about one (seed, configuration) pair in five contains a
    /// sampler that can never be satisfied. See NOTES.md.
    ///
    /// So: **0 for anything that must reproduce**, and ``hardwareStirInterval``
    /// for anything that wants to behave like the game.
    public var stirInterval = 0

    /// One raster interrupt's worth of draws, which is what the game stirs at.
    ///
    /// Derived rather than picked: the World Maker runs 219 interpreter steps
    /// per draw measured over seed `$1234` configuration 0 (1,612,709 draws
    /// across 353,513,921 steps), and a PAL frame is about 5,000 steps of this
    /// code. That puts one interrupt at a little over twenty draws.
    public static let hardwareStirInterval = 23

    /// How many times the register has been stirred.
    public private(set) var stirs = 0

    /// `$2406`, standing in for the SID.
    ///
    /// The original's entropy is oscillator 3's noise output. There is no SID
    /// here, so this takes the system's randomness, which is the faithful
    /// analogue: the point was never *which* bits, only that they keep arriving.
    private mutating func stir() {
        high = high &+ UInt8.random(in: 0...255)
        stirs += 1
    }

    /// Creates a generator seeded with a 16-bit value.
    ///
    /// The original seeded this by reading the SID's oscillator twice, giving
    /// 65,536 distinct worlds.
    public init(seed: UInt16) {
        self.high = UInt8(truncatingIfNeeded: seed >> 8)
        self.low = UInt8(truncatingIfNeeded: seed)
    }

    /// Creates a generator from the raw zero-page byte pair.
    public init(high: UInt8, low: UInt8) {
        self.high = high
        self.low = low
    }

    /// 6502 `ROL`: a nine-bit rotate left through carry.
    ///
    /// Returns the rotated value and the bit shifted out into carry.
    private static func rol(_ value: UInt8, _ carryIn: Bool) -> (UInt8, Bool) {
        let out = value & 0x80 != 0
        return ((value << 1) | (carryIn ? 1 : 0), out)
    }

    /// Advances the register eight steps and returns the next value.
    public mutating func next() -> UInt8 {
        draws += 1
        if stirInterval > 0, draws % stirInterval == 0 { stir() }
        for _ in 0..<8 {
            // CLC / LDA $CD / ROL A x4 / AND #$02 / STA $CE
            var rotated = high
            var carry = false
            for _ in 0..<4 {
                (rotated, carry) = Self.rol(rotated, carry)
            }
            let tapHigh = rotated & 0x02

            // LDA $CF / AND #$02 / CLC / EOR $CE / BEQ +1 / SEC
            let tapLow = low & 0x02
            let feedback = (tapLow ^ tapHigh) != 0

            // ROL $CF / ROL $CD — 16-bit shift, low byte first.
            let (newLow, carryOut) = Self.rol(low, feedback)
            low = newLow
            (high, _) = Self.rol(high, carryOut)
        }

        // LDA $CD / ORA $CF / BNE +2 / INC $CD — never rest at all zeros.
        if high | low == 0 {
            high &+= 1
        }

        return low
    }
}

/// Bounded draws, as the World Maker makes them.
///
/// Both are **rejection samplers**: they keep advancing the register until a
/// value lands inside the range, rather than reducing one draw by modulo or
/// scaling. That distinction is not cosmetic — rejection consumes a variable
/// number of LFSR steps, so every later draw in the sequence depends on how
/// many candidates were thrown away. Reproducing the original's worlds requires
/// reproducing the waste.
///
/// Transcribed from `$22B4` and `$247B` in `game3`. Both are self-modifying
/// there: `$22B4` writes its bounds into the operand bytes of its own two `CMP`
/// instructions at `$22E8` and `$22EC`, which is why a plain reading of the
/// listing shows `CMP #$FF` twice.
extension WorldMakerRNG {

    /// A byte in `from ..< below`, by rejection (`$22B4`).
    ///
    /// When `from >= below` this returns `from` without advancing the register,
    /// matching the guard at `$22BA` (`CMP $22EC / BCS`).
    ///
    /// The bounds are two parameters rather than a `Range` deliberately. Swift's
    /// `Range` traps at construction when inverted, so it cannot represent the
    /// case the original explicitly handles — expressing these bounds as a
    /// `Range` would impose an invariant the 6502 does not have and turn a
    /// reachable path into a crash.
    public mutating func nextByte(from lower: UInt8, below upper: UInt8) -> UInt8 {
        guard lower < upper else { return lower }
        while !isStuck {
            let value = next()
            if value >= lower && value < upper { return value }
        }
        return lower
    }

    /// A byte reduced modulo `limit` (`$0ACB`).
    ///
    /// **Not** the same sampler as ``nextByte(from:below:)``, and the difference
    /// shows up in the LFSR sequence rather than in any one value: this takes
    /// exactly **one** draw and reduces it by repeated subtraction, where
    /// `$22B4` rejects and redraws until a candidate lands in range.
    ///
    /// A limit below 2 returns 0 **without drawing at all** (`$0ACE`), so it
    /// does not advance the register. Like `$22B4`, the original self-modifies —
    /// the limit is written into the operand byte at `$0AD9` shared by its own
    /// `CMP` and `SBC`.
    public mutating func nextModulo(_ limit: UInt8) -> UInt8 {
        guard limit >= 2 else { return 0 }
        var value = next()
        while value >= limit {
            value &-= limit
            if value == 0 { break }
        }
        return value
    }

    /// A 16-bit value in `from ..< below`, by rejection (`$247B`).
    ///
    /// Two register advances per candidate, not one. The first supplies the low
    /// byte; the second is drawn only for its **sign**, and the high byte is 1
    /// when that draw is below `$80` and 0 otherwise (`LDA $CF / BMI / INX` at
    /// `$24E1`). That caps the result at 511, which is all the map's 400 rows
    /// need. A rejected candidate re-draws both.
    ///
    /// The original only short-circuits when the bounds are exactly equal, so an
    /// inverted range spins forever. That hazard is preserved rather than papered
    /// over — every caller derives its bounds from a landmass radius and cannot
    /// invert them — but it is a hang rather than merely a wrong answer, so a new
    /// caller must not pass one. The watchdog turns the hang into a thrown
    /// ``WorldMakerRNG/Stuck``; it does not make the call correct.
    public mutating func nextWord(from lower: UInt16, below upper: UInt16) -> UInt16 {
        // $247F / $2487: equal bounds return the lower bound unsampled.
        if lower == upper { return lower }
        while !isStuck {
            let low = next()
            let high: UInt8 = next() < 0x80 ? 1 : 0
            let value = UInt16(high) << 8 | UInt16(low)
            if value >= lower && value < upper { return value }
        }
        return lower
    }

    /// A value scattered around `mean` (`$0B16`).
    ///
    /// Twelve draws summed, centered, halved, scaled by `spread` and added to the
    /// mean — the central-limit trick, so the result is bell-shaped rather than
    /// flat. That is what gives the mountain walkers their wandering line: a
    /// uniform step would fray, and this one drifts.
    ///
    /// Two details a port has to keep. It costs **twelve** register advances, not
    /// one, which matters everywhere the sequence is graded. And the clamp at the
    /// end is on the *sign bit of a byte*, so anything from `$80` up comes back as
    /// zero — a mean above 127 always does, and every caller here stays well
    /// below that.
    ///
    /// A spread of zero returns the mean without drawing at all (`$0B18`).
    ///
    /// `offset` is the routine's other output, and it is not a tidy one: `$03`
    /// holds the high byte of the scaled draw, *before* the clamp, and `$328A`
    /// reads it directly off the zero page to recover a signed step the clamped
    /// return value has already thrown away. Callers that only want the value
    /// ignore it. A spread of zero leaves it stale in the original; here it is
    /// zero, and no caller with a spread of zero reads it.
    public mutating func nextScattered(around mean: UInt8, spread: UInt8)
        -> (value: UInt8, offset: UInt8) {
        guard spread != 0 else { return (mean, 0) }
        var sum = 0
        for _ in 0..<12 { sum += Int(next()) }
        // $0B5D: less 1536, then an arithmetic shift right — the sign is carried
        // in by $0B6A's ASL of the high byte.
        let centered = (sum - 1536) >> 1
        // $0B83 is a 16-bit multiply and only the low word is kept, so the
        // two's-complement multiplicand needs no sign handling.
        let product = (centered * Int(spread)) & 0xFFFF
        // $0B79: the +$80 is the rounding, and its carry joins the high byte.
        let carry = (product & 0xFF) + 0x80 > 0xFF ? 1 : 0
        let value = (Int(mean) + (product >> 8) + carry) & 0xFF
        return (value < 0x80 ? UInt8(value) : 0,          // $0B7E
                UInt8(product >> 8))
    }
}
