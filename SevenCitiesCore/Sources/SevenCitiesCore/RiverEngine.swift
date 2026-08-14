/// The water engine — one river walker, reached from three places.
///
/// `$380D`, `$3961` and `$3EAD` are not three phases that happen to look alike.
/// They are three *entries* into this, and they share 776 of their addresses.
/// `$32CC` is the setup, and it tells the engine which one called it by writing
/// the caller's two addresses into the operands of `$3450` and `$348A` — the two
/// places the walk hands control back. So the engine's exits are a hole the
/// caller fills, and a port has to model them as such.
///
/// What the engine does with a river is walk it, record it, and be ready to take
/// it back: `$3300` writes each step into a table in high RAM as it goes, and
/// `$33EF` walks that table backwards overwriting the cells with plain and
/// forest again. A river that cannot finish is erased rather than left.
public struct RiverEngine: Sendable {

    // MARK: - The tables at `$329C`

    /// `$32AC`: the four directions, as `(dx, dy)`. South, west, east, north.
    static let steps: [(dx: Int8, dy: Int8)] = [(0, 1), (-1, 0), (1, 0), (0, -1)]

    /// `$32B4`: where a turn goes, indexed by `direction * 2 + bend`.
    ///
    /// Every entry turns — 0 becomes 1 or 2, 1 becomes 0 or 3 — so `bend` is
    /// which way the river is curving and `$333C` flips it on a draw.
    static let turns: [UInt8] = [1, 2, 0, 3, 0, 3, 1, 2]

    /// `$329C`: the nibble to write, indexed by `new * 4 + old`.
    ///
    /// This is what settles the map's river tiles: `5` to `A` are **connection
    /// masks**, one value per pair of directions the water enters and leaves by,
    /// not depths. `nil` marks the four reversals, which `$33C1` refuses by
    /// drawing a direction again.
    static let tiles: [UInt8?] = [
        0x08, 0x0A, 0x07, nil,
        0x06, 0x05, nil, 0x07,
        0x09, nil, 0x05, 0x0A,
        nil, 0x09, 0x06, 0x08,
    ]

    /// How many steps either high-RAM table holds. `$3459` and `$35A5` wrap the
    /// index at `$FB` and `$3617` refuses to record past it.
    public static let recordLimit = 0xFB

    // MARK: - State

    /// One recorded step: where the water was and which way it was going.
    /// Three bytes at `$E000` plus three times the index (`$33DB`).
    public struct Step: Sendable, Equatable {
        public var row: UInt8
        public var column: UInt8
        public var direction: UInt8
    }

    /// A river mouth: `$3615` files these at `$E2F1`, indexed by `$56`.
    public struct Mouth: Sendable, Equatable {
        public var row: UInt8
        public var column: UInt8
        public var length: UInt8
    }

    /// `$39`, the direction the walk holds to between turns.
    var heading: UInt8 = 0
    /// `$3A`, the direction the last step actually took.
    public internal(set) var last: UInt8 = 0
    /// `$3B`, which way the river is bending.
    var bend: UInt8 = 0
    /// `$3C`, how far it has come — counted up while drawing, down while erasing.
    var length: UInt8 = 0
    /// `$46`, the index of the current step, and `$2B`, set until it first wraps.
    public internal(set) var index: UInt8 = 0xFF
    var wrapped: UInt8 = 0xFF
    /// `$5D` and `$5E`, the direction chosen and the tile it writes.
    var chosen: UInt8 = 0
    public internal(set) var tile: UInt8 = 0
    /// `$5F`, how strongly the walk holds its heading, as `$32CC` copied it out
    /// of `$32FC` at the start of this walk.
    var persistence: UInt8 = 0xAA

    /// `$32FC` and `$33F0` themselves — two *operands*, patched in place and
    /// left patched. They outlive a river, a phase and a band.
    ///
    /// The order is the trap. `$38BB` calls `$32CC`, which copies `$32FC` into
    /// `$5F`, and only *then* do `$38C3` and `$38C8` write `$0A` and `$AA` into
    /// the two operands — so a `$380D` river runs with whatever the last one
    /// left, not with what the lines just above it appear to set. Band 0's last
    /// river finishes and `$38F3` leaves `$B4` behind; band 0's `$3961` and
    /// `$3EAD` inherit it, and so does band 1's first `$380D`.
    public var patchedPersistence: UInt8 = 0xAA
    public var patchedAllowance: UInt8 = 0x06
    /// `$14`/`$15`, where the water is, and `$16`/`$17`, where it is going.
    public internal(set) var column: UInt8 = 0
    public internal(set) var row: Int = 0
    public internal(set) var nextColumn: UInt8 = 0
    public internal(set) var nextRow: Int = 0

    /// A river as `$3755` files it: two entries, one for each end.
    ///
    /// `$E681` holds the column, `$E6D1`/`$E721` the row as sixteen bits with
    /// the second band offset by `$C0`, and `$E771` the length — positive at the
    /// source and negated at the mouth, which is how the pair is recognised as a
    /// pair. `$EBCA` accumulates the total.
    public struct Source: Sendable, Equatable {
        public var column: UInt8
        public var row: UInt16
        public var length: Int8
    }
    public var sources: [Source] = []
    /// `$EBCA`, the total river length on the map.
    public var totalLength: UInt16 = 0

    /// `$E000` and `$E2F1`. Both are ring buffers of `recordLimit` entries.
    public var record: [Step] = []
    public var mouths: [Mouth] = []
    /// `$4F`, the index the caller marked before its last step.
    public internal(set) var stopIndex: UInt8 = 0
    /// `$76` and `$37`, where the river started, and `$22`, the landmass it
    /// belongs to — all three outlive the walk and the swamp placement reads
    /// them.
    public internal(set) var sourceColumn: UInt8 = 0
    public internal(set) var sourceRow: Int = 0
    public internal(set) var landmassColumn: UInt8 = 0
    /// `$56`, which is a *byte* offset into `$E2F1` rather than an entry count.
    var mouthBytes: UInt8 = 0

    // MARK: - Setup

    public init() {}

    /// `$32CC`: start a walk.
    ///
    /// The record and the mouth table survive it — they are memory, and `$56` is
    /// only cleared once a band by `$0E40` — but everything about the walk
    /// itself is reset. The original also writes the caller's two addresses into
    /// the operands of `$3450` and `$348A`, which is how the engine knows who to
    /// hand back to; here the caller keeps hold of the walk instead, which is
    /// the same thing said in a language that has values.
    public mutating func start(heading: UInt8) {
        self.heading = heading
        self.last = heading
        self.persistence = patchedPersistence                 // $32FB
        bend = 0
        length = 0
        index = 0xFF
        wrapped = 0xFF
    }

    /// `$0E40`: the mouth table is cleared once a band, not once a river.
    public mutating func beginBand() {
        mouths.removeAll()
        mouthBytes = 0
    }

    /// `$3755`: file a finished river, both ends of it.
    ///
    /// Two entries — the source at `$76`/`$37` and the mouth where the walk
    /// stopped — with the length written positive on the first and negated on
    /// the second. `$3772` caps it at `$7F` first, so a river longer than 127
    /// steps is recorded as 127.
    mutating func fileSource(from column: UInt8, _ row: Int,
                             secondBand: Bool) {
        let offset: UInt16 = secondBand ? 0xC0 : 0
        var capped = length
        if capped >= 0x80 { capped = 0x7F }                   // $3774
        length = capped
        sources.append(Source(column: column,
                              row: UInt16(row) &+ offset,
                              length: Int8(bitPattern: capped)))
        totalLength &+= UInt16(capped)                        // $3780
        sources.append(Source(column: self.column,
                              row: UInt16(self.row) &+ offset,
                              length: Int8(bitPattern: 0 &- capped)))
    }

    /// `$34F3`: is there a lake mark within eight cells of where the walk is
    /// about to step?
    ///
    /// The marks are the `$0F` that `$2D23` laid around each lake, and a river
    /// is not allowed to run into one. Returns false when a mark is found, which
    /// is the carry the original clears.
    func clearOfLakes(in band: TerrainBand) -> Bool {
        let area = TerrainPhases.box(around: nextColumn,
                                     UInt8(truncatingIfNeeded: nextRow),
                                     radius: 8)
        return TerrainPhases.unmarked(area, in: band)
    }

    /// `$3688`: the three directions that are not a reversal of the last one.
    ///
    /// `$32BC` holds them, four to a row with `$FF` where the reversal would be,
    /// so `last * 4` plus nought, one and two are the three a walk may look
    /// along.
    static let lookahead: [UInt8] = [0, 2, 4, 0xFF,
                                     2, 0, 6, 0xFF,
                                     4, 0, 6, 0xFF,
                                     6, 2, 4, 0xFF]

    // MARK: - Walking

    /// `$333C`: choose the next direction.
    ///
    /// A scattered draw around zero sets the threshold to hold by — and it reads
    /// `$03` rather than the value, so the offset is signed and `$5F` is the
    /// middle of the range. One draw against that decides hold or turn; a second
    /// above `$BF` flips the bend; and `$32B4` says where a turn goes.
    mutating func choose(rng: inout WorldMakerRNG) {
        let threshold = rng.nextScattered(around: 0, spread: 4).offset
            &+ persistence
        if rng.next() < threshold {
            chosen = heading                                  // $3376
            return
        }
        if rng.next() >= 0xBF { bend ^= 1 }                   // $33A6
        chosen = Self.turns[Int(heading) * 2 + Int(bend)]     // $33B2
    }

    /// `$33B7`: the tile the turn makes and the cell it moves to.
    ///
    /// Returns false when the pair of directions is a reversal, which `$33C1`
    /// answers by choosing again.
    mutating func aim() -> Bool {
        guard let nibble = Self.tiles[Int(chosen) * 4 + Int(last)] else {
            return false                                      // $33C1
        }
        tile = nibble
        let step = Self.steps[Int(last)]
        nextColumn = column &+ UInt8(bitPattern: step.dx)
        nextRow = row + Int(step.dy)
        return true
    }

    /// `$3300`: take the step — record it, and put the tile down.
    ///
    /// The index wraps at `$FB`, and `$330C` clears `$2B` when it does, which is
    /// how the erase at `$3447` knows the record has gone all the way round.
    mutating func take(in band: inout TerrainBand) {
        index &+= 1
        if index >= 0xFB {                                    // $3304
            index = 0
            wrapped = 0
        }
        row = nextRow
        column = nextColumn
        write(Step(row: UInt8(truncatingIfNeeded: row), column: column,
                   direction: chosen), at: index)
        band[column, row] = tile                              // $3327
        if length != 0xFF { length &+= 1 }                    // $332F
        last = chosen                                         // $3337
    }

    /// `$33B7` with `$33C1`'s retry: aim, and choose again for as long as the
    /// pair of directions is one the tables refuse.
    ///
    /// `$333C` falls straight into `$33B7`, so a refusal is a loop rather than a
    /// call — and the choosing it does on the way round costs draws.
    mutating func aim(rng: inout WorldMakerRNG) {
        while !aim() { choose(rng: &rng) }
    }

    /// `$363B`: `count` steps, each one starting from the held heading.
    ///
    /// It sets `$5D` to `$39` every step rather than choosing, so the river runs
    /// straight — unless the tables refuse the pair, and then `$33C1` sends it
    /// through `$333C` after all.
    mutating func run(_ count: UInt8, in band: inout TerrainBand,
                      rng: inout WorldMakerRNG) {
        var remaining = count
        repeat {
            chosen = heading                                  // $363D
            aim(rng: &rng)
            take(in: &band)
            remaining &-= 1
        } while remaining != 0
    }

    // MARK: - The record

    private mutating func write(_ step: Step, at index: UInt8) {
        while record.count <= Int(index) {
            record.append(Step(row: 0, column: 0, direction: 0))
        }
        record[Int(index)] = step
    }

    /// The step `index` points at, which is what `$3463` reads back.
    func step(at index: UInt8) -> Step {
        Int(index) < record.count ? record[Int(index)]
                                  : Step(row: 0, column: 0, direction: 0)
    }

    // MARK: - Taking it back

    /// Which way `$33EF` handed control back.
    public enum Unwind: Sendable {
        /// `$3450`: the record ran out — there is nothing left of this river.
        case exhausted
        /// `$348A`: the erase used up its allowance and stopped somewhere that
        /// is not open water, so the caller can carry on from there.
        case stopped
    }

    /// `$33EF`: walk the record backwards, putting the land back.
    ///
    /// A river that cannot finish is not left half-drawn; the engine erases it
    /// cell by cell, plain or forest on a coin flip, following the record it
    /// kept on the way out. `allowance` is `$33F0`'s operand — ten from `$38C3`,
    /// six from `$38F0` — and `stop` is `$4F`, the index the caller marked
    /// before its last step.
    ///
    /// Stepping back over a river mouth takes it off the mouth table as well
    /// (`$33FE`), which is the only place `$56` ever goes down.
    mutating func erase(allowance: UInt8, stop: UInt8, in band: inout TerrainBand,
                        rng: inout WorldMakerRNG) -> Unwind {
        var remaining = allowance
        while true {
            // $33F3: a mouth here is a mouth no longer.
            if band[column, row] == 0x04 && mouthBytes != 0 {
                mouthBytes &-= 3
                if mouths.count * 3 > Int(mouthBytes) {
                    mouths.removeLast()
                }
            }
            // $3408: plain, or forest on the sign of a draw.
            band[column, row] = Int8(bitPattern: rng.next()) < 0 ? 0x0C : 0x0B
            if length != 0 { length &-= 1 }                   // $3441

            // $3447: nothing before this, so there is nothing to go back to.
            if wrapped != 0 && index == 0 { return .exhausted }
            if index == stop { return .exhausted }            // $3453

            index = index == 0 ? 0xFA : index &- 1            // $3457
            let previous = step(at: index)
            row = Int(previous.row)
            column = previous.column
            last = previous.direction

            remaining &-= 1
            if remaining != 0 { continue }
            // $347B: out of allowance. Open water underfoot buys one more step,
            // which is how the erase keeps going until it is clear of the river
            // it is unwinding.
            if band[column, row] == 0x04 { remaining = 1; continue }
            return .stopped
        }
    }

    // MARK: - Mouths

    /// `$3531`: find where this river meets the sea, and file it.
    ///
    /// Walks fifteen steps back along the record. The cell three steps back is
    /// the candidate; the four after it must still carry this river's own tile,
    /// and none of the fifteen may be a `$4` already. Then the candidate's four
    /// neighbours are counted, and it is a mouth only if **fewer than three** of
    /// them are river or shallow — the edges of the band counting as if they
    /// were.
    ///
    /// It gives up before it starts unless the river is at least twenty steps
    /// long and its last tile was a `$5` or an `$8`: a straight run, not a bend.
    ///
    /// What it files at `$E2F1` is row, column and the river's length, and it
    /// puts a `$4` down — the same nibble the shallows use, which is why a mouth
    /// reads as navigable water rather than as river.
    mutating func fileMouth(in band: inout TerrainBand, sourcesFull: Bool)
        -> Bool {
        guard !sourcesFull else { return false }              // $3534
        guard length >= 0x14 else { return false }            // $353A
        guard tile == 0x05 || tile == 0x08 else { return false } // $3540

        var countdown: UInt8 = 0x0F                           // $3548
        var probe = index                                     // $354C
        let ceiling = index &+ 1                              // $3553
        var mouth: Step?

        while true {
            // $3555: the same two guards the erase stops on.
            if wrapped != 0 && probe == 0 { return false }
            if probe == ceiling { return false }              // $355F
            let candidate = step(at: probe)

            if countdown == 0x0F {
                // The first look back records nothing at all.
                _ = candidate                                 // $3569
            } else if countdown >= 0x0B {
                if countdown == 0x0D { mouth = candidate }    // $3574, $357F
                let nibble = band[candidate.column, Int(candidate.row)]
                if nibble == 0x04 { return false }            // $358A
                if nibble != tile { return false }            // $358E
            } else {
                // $3592: a shallow anywhere further back and this is not a mouth.
                if band[candidate.column, Int(candidate.row)] == 0x04 {
                    return false
                }
            }

            probe = probe == 0 ? 0xFA : probe &- 1            // $35A1
            countdown &-= 1
            if countdown == 0 { break }                       // $35AD
        }

        guard let mouth else { return false }
        // $35B1: how many of the four neighbours are river or shallow — nibble
        // `$4` through `$A`. Running off the band counts as one, which is what
        // stops a mouth being filed against the edge of the map.
        var crowded = 0
        func occupied(_ column: UInt8, _ row: Int) -> Bool {
            let nibble = band[column, row]
            return nibble >= 0x04 && nibble < 0x0B
        }
        if mouth.column == 0 || occupied(mouth.column &- 1, Int(mouth.row)) {
            crowded += 1                                      // $35BC
        }
        if mouth.column == 0xFF || occupied(mouth.column &+ 1, Int(mouth.row)) {
            crowded += 1                                      // $35CE
        }
        if mouth.row == 0 || occupied(mouth.column, Int(mouth.row) - 1) {
            crowded += 1                                      // $35E0
        }
        if mouth.row >= 0xCE || occupied(mouth.column, Int(mouth.row) + 1) {
            crowded += 1                                      // $35F6
        }
        guard crowded < 3 else { return false }               // $3610

        guard mouthBytes < 0xFB else { return false }         // $3617
        mouths.append(Mouth(row: mouth.row, column: mouth.column,
                            length: length))
        mouthBytes &+= 3
        band[mouth.column, Int(mouth.row)] = 0x04             // $3636
        return true
    }
}
