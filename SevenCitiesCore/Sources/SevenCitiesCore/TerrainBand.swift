/// The map as the terrain phases see it: a band of nibbles at `$5700`.
///
/// The land-mass phase leaves a 1-bit mask there, 32 bytes a row. Everything
/// after it works on **4 bits a cell, 128 bytes a row**, in the same memory — the
/// nibble map overwrites the mask in place. A band is 208 rows, which is what
/// `$2C14` bounds its row counter at and what `$2A45` clamps its bounding boxes
/// to, and 400 rows of map take two of them: rows 0 to 207 and rows 192 to 399,
/// **overlapping by sixteen**. The second band therefore starts with sixteen rows
/// of terrain the first band already generated, which is not something a port can
/// paper over — those rows are the seam the two halves are stitched along.
///
/// The two addressings share their machinery. `$2AF1` patches `$141C` and `$1B4E`
/// — the 1-bit row-pointer and cell-test routines — into `JMP $0FAE` and
/// `JMP $0FC3`, and `$2B02` rewrites the bit-mask table at `$13D3` from
/// `80 40 20 10 ...` to `F0 0F`. After that every routine built on them, `$22F7`'s
/// clearance test included, is working on nibbles without knowing it.
public struct TerrainBand: Sendable, Equatable {

    /// `$2C14`'s bound, and the height of a band.
    public static let rows = 208
    /// `$0FAE` shifts the row left seven.
    public static let bytesPerRow = 128
    public static let width = 256
    public static let byteCount = rows * bytesPerRow          // 26,624

    /// Where the second band starts, so that the two cover 400 rows.
    public static let secondBandRow = LandMask.height - rows  // 192

    private var bytes: [UInt8]

    /// One cell written, for the diagnostic journal below.
    public struct Write: Sendable, Equatable {
        public let x: UInt8, y: Int, nibble: UInt8
    }

    /// Every write in order, when it is switched on.
    ///
    /// The original funnels all of them through `$0FD3`, and `tools/range_trace.py`
    /// records the sequence off the interpreter — so a port that disagrees can be
    /// diffed write by write instead of being told only that a digest is wrong.
    /// It is `nil` unless a diagnostic asks for it.
    public var journal: [Write]?

    public init() {
        bytes = [UInt8](repeating: 0, count: Self.byteCount)
    }

    /// The band as `$0C9B` unpacks it out of the land mask.
    ///
    /// One bit becomes one nibble: water `$0`, land `$B` — deep water and plain.
    /// The original does it by shifting bytes of its own instruction stream, which
    /// is worth knowing about and not worth reproducing; the result is this.
    public init(landMask: LandMask, fromRow first: Int) {
        self.init()
        for row in 0..<Self.rows {
            let source = first + row
            guard source < LandMask.height else { break }
            for column in 0..<Self.width where landMask.isLand(x: UInt8(column),
                                                               y: source) {
                self[UInt8(column), row] = 0x0B
            }
        }
    }

    /// The raw bytes, for hashing against a captured band.
    public var storage: [UInt8] { bytes }

    /// Byte index and which half, as `$0FAE` and `$0FC3` compute them: the row
    /// shifted left seven plus half the column, and **even columns are the high
    /// nibble**.
    @inlinable
    public static func address(x: UInt8, y: Int) -> (index: Int, high: Bool) {
        (y * bytesPerRow + Int(x) / 2, x & 1 == 0)
    }

    /// One cell (`$0FEA` to read, `$0FD3` to write).
    ///
    /// Rows outside the band read as `$0` and swallow writes. The original has no
    /// such guard — it would address whatever lay beyond — but nothing has been
    /// seen to go there, and a Swift array would trap rather than shrug.
    public subscript(x: UInt8, y: Int) -> UInt8 {
        get {
            guard y >= 0 && y < Self.rows else { return 0 }
            let (index, high) = Self.address(x: x, y: y)
            return high ? bytes[index] >> 4 : bytes[index] & 0x0F
        }
        set {
            guard y >= 0 && y < Self.rows else { return }
            let (index, high) = Self.address(x: x, y: y)
            bytes[index] = high ? (bytes[index] & 0x0F) | (newValue << 4)
                                : (bytes[index] & 0xF0) | (newValue & 0x0F)
            journal?.append(Write(x: x, y: y, nibble: newValue))
        }
    }

    /// How many of each nibble the band holds — what the fixtures record
    /// alongside the digest, because it is what makes a failure legible.
    public var histogram: [UInt8: Int] {
        var counts: [UInt8: Int] = [:]
        for byte in bytes {
            counts[byte >> 4, default: 0] += 1
            counts[byte & 0x0F, default: 0] += 1
        }
        return counts
    }
}
