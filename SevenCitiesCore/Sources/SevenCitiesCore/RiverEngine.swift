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
    var last: UInt8 = 0
    /// `$3B`, which way the river is bending.
    var bend: UInt8 = 0
    /// `$3C`, how far it has come — counted up while drawing, down while erasing.
    var length: UInt8 = 0
    /// `$46`, the index of the current step, and `$2B`, set until it first wraps.
    var index: UInt8 = 0xFF
    var wrapped: UInt8 = 0xFF
    /// `$5D` and `$5E`, the direction chosen and the tile it writes.
    var chosen: UInt8 = 0
    var tile: UInt8 = 0
    /// `$5F`, how strongly the walk holds its heading. `$32FC`'s operand, so the
    /// caller sets it: `$AA` from `$38C8` and `$B4` from `$38F3`.
    var persistence: UInt8 = 0xAA
    /// `$14`/`$15`, where the water is, and `$16`/`$17`, where it is going.
    var column: UInt8 = 0
    var row: Int = 0
    var nextColumn: UInt8 = 0
    var nextRow: Int = 0

    /// `$E000` and `$E2F1`. Both are ring buffers of `recordLimit` entries.
    public var record: [Step] = []
    public var mouths: [Mouth] = []
    /// `$56`, which is a *byte* offset into `$E2F1` rather than an entry count.
    var mouthBytes: UInt8 = 0

    // MARK: - Setup

    /// `$32CC`: start a walk, and tell the engine who to hand back to.
    ///
    /// The original writes the caller's two addresses into `$3450` and `$348A`.
    /// Here the caller is a value instead, which is the same thing said in a
    /// language that has them.
    public init(heading: UInt8, persistence: UInt8 = 0xAA) {
        self.heading = heading
        self.last = heading
        self.persistence = persistence
    }

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
}
