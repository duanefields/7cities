/// The World Maker's land/water bitmap — one bit per map cell.
///
/// The generator builds land as a **1-bit mask** before any terrain exists,
/// living at `$5700` with 32 bytes per row: bit `$80 >> (x & 7)` of byte
/// `y * 32 + x / 8`. Confirmed by dumping `$5700` from the original at the end
/// of the land-mass phase and rendering it both ways — at 32 bytes per row it is
/// continents with coastlines, at 128 it is the same data repeated four times.
///
/// Do not confuse this with the map proper. `game3` uses **two** addressings of
/// the same base: `$141C` (shift 5, 32 bytes per row, 1 bit per cell) for this
/// mask, and `$0FAE` (shift 7, 128 bytes per row, 4 bits per cell) for the
/// terrain nibbles that eventually reach the disk. Mixing them up produces
/// output that looks structured and is wrong.
///
/// ### Why the buffer is bigger than the map
///
/// The map is 400 rows and ends at `$88FF`, but the original's own bounds check
/// is looser than that: `$1900` compares the row pointer's high byte against
/// `$50` and `$91`, and only restarts generation outside that window. Rows up to
/// about 460 therefore address unused RAM below the walker's record ring at
/// `$9100` without tripping anything.
///
/// **No such spill has actually been observed** — dumping `$5700..$90FF` after
/// the phase shows every byte past row 400 still zero. The buffer is sized to
/// the guard rather than to the map anyway, because the cost is 2 KB and the
/// alternative failure mode is bad: a Swift array sized exactly to the map would
/// *trap* on a write the original would have absorbed silently, turning a
/// faithful-but-odd path into a crash. ``mapBytes`` returns just the 12,800
/// bytes that are the map.
public struct LandMask: Sendable, Equatable {

    /// Base address in the original, for cross-referencing the disassembly.
    public static let base = 0x5700
    /// Where the coastline walker's record ring begins — the buffer's ceiling.
    public static let ceiling = 0x9100

    public static let width = 256
    public static let height = 400
    public static let bytesPerRow = 32

    /// Bytes of the map proper, `height * bytesPerRow`.
    public static let mapByteCount = height * bytesPerRow          // 12,800

    /// The whole region the original will write into without complaint.
    public static let byteCount = ceiling - base                   // 14,848

    private var bytes: [UInt8]

    public init() {
        bytes = [UInt8](repeating: 0, count: Self.byteCount)
    }

    /// The map's 12,800 bytes, in the original's layout — what a captured dump
    /// of `$5700` should equal.
    public var mapBytes: [UInt8] { Array(bytes[0..<Self.mapByteCount]) }

    /// Rows the buffer can address before the original's guard would fire.
    public static var addressableRows: Int { byteCount / bytesPerRow }   // 464

    /// Whether the row is inside the buffer at all. The original's own guard at
    /// `$1900` compares the pointer's high byte against `$50` and `$91`.
    public static func isAddressable(row y: Int) -> Bool {
        y >= 0 && y < addressableRows
    }

    /// Byte offset and bit mask for a cell, exactly as `$141C` and `$142F`
    /// compute them: `y * 32 + (x >> 3)`, and `$13D3 + (x & 7)` which is
    /// `80 40 20 10 08 04 02 01`.
    ///
    /// `x` is a byte in the original and cannot leave 0...255, so only the row
    /// needs checking.
    @inlinable
    public static func address(x: UInt8, y: Int) -> (offset: Int, mask: UInt8) {
        (y * bytesPerRow + Int(x >> 3), 0x80 >> (x & 7))
    }

    /// Tests a cell (`$1B4E`). Rows outside the buffer read as water rather than
    /// trapping; the original would be reading whatever RAM lay there.
    public func isLand(x: UInt8, y: Int) -> Bool {
        guard Self.isAddressable(row: y) else { return false }
        let (offset, mask) = Self.address(x: x, y: y)
        return bytes[offset] & mask != 0
    }

    /// Sets a cell (`$1728`: `ORA $13D3,X / STA ($29),Y`).
    public mutating func setLand(x: UInt8, y: Int) {
        guard Self.isAddressable(row: y) else { return }
        let (offset, mask) = Self.address(x: x, y: y)
        bytes[offset] |= mask
    }

    /// Clears a cell (`$1B3B`: `LDA $13D3,X / EOR #$FF / AND ($29),Y`).
    ///
    /// The coastline walker is a backtracking search and erases what it drew
    /// when it unwinds, so land is not write-once. An earlier version of this
    /// file asserted the original had no way to clear a bit, which was simply
    /// wrong — `$1B3B` had not been read yet.
    public mutating func clearLand(x: UInt8, y: Int) {
        guard Self.isAddressable(row: y) else { return }
        let (offset, mask) = Self.address(x: x, y: y)
        bytes[offset] &= ~mask
    }

    /// Number of land cells within the map proper.
    public var landCells: Int {
        bytes[0..<Self.mapByteCount].reduce(0) { $0 + $1.nonzeroBitCount }
    }

    /// Mirrors every row left to right (`$1C9C`).
    ///
    /// A full 256-bit reversal per row, which the original does in two passes
    /// through a scratch buffer at `$9100`: `LSR A / ROL` eight times reverses the
    /// bits of a byte, and copying back with the index counting the other way
    /// reverses the bytes. Cell `x` ends up at `255 - x`.
    public mutating func mirrorHorizontally() {
        for row in 0..<Self.height {
            let start = row * Self.bytesPerRow
            var reversed = [UInt8](repeating: 0, count: Self.bytesPerRow)
            for byte in 0..<Self.bytesPerRow {
                reversed[Self.bytesPerRow - 1 - byte] = bytes[start + byte].reversedBits
            }
            bytes.replaceSubrange(start..<(start + Self.bytesPerRow), with: reversed)
        }
    }

    /// Flips the map top to bottom (`$1CE7`).
    ///
    /// Row `r` swaps with row `399 - r`, and the loop runs `r` from 0 to 199 so
    /// each pair is swapped once. Only the map proper moves — the spare rows above
    /// it are not touched.
    public mutating func flipVertically() {
        for row in 0..<(Self.height / 2) {
            let top = row * Self.bytesPerRow
            let bottom = (Self.height - 1 - row) * Self.bytesPerRow
            for byte in 0..<Self.bytesPerRow {
                bytes.swapAt(top + byte, bottom + byte)
            }
        }
    }
}

private extension UInt8 {
    /// The eight bits in the opposite order, as `LSR A / ROL` builds them.
    var reversedBits: UInt8 {
        var source = self
        var result: UInt8 = 0
        for _ in 0..<8 {
            result = (result << 1) | (source & 1)
            source >>= 1
        }
        return result
    }
}
