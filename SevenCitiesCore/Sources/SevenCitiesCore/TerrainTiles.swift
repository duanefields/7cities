import Foundation

/// The original's terrain art, read out of the main program.
///
/// The exploration view draws terrain as **redefined characters**, which is why
/// no charset exists anywhere on either disk and why an earlier attempt had to
/// screenshot a running game. But only the *charset* is assembled at runtime —
/// the tile bitmaps themselves are static data inside `game`. Decrypt it and
/// they can be read directly, so the classic tileset needs no emulator and no
/// captured pixels.
///
/// The view is a 12x12 grid of unique character codes over 6x6 map tiles, so
/// **one tile is 2x2 characters**: 8 multicolor pixels across by 16 rows down,
/// 32 bytes. `terrainDispatch` is the original's own table of pattern addresses,
/// one per terrain value.
///
/// See NOTES.md for the routines this was traced from (`$3107`, `$31B4`,
/// `$58B8`).
public struct TerrainTiles: Sendable {

    /// Where the original keeps its pattern-address table.
    public static let terrainDispatch = 0x5529
    /// `game` loads here, so a pattern address minus this is a file offset.
    public static let loadAddress = 0x0800
    public static let bytesPerTile = 32
    public static let width = 8
    public static let height = 16

    /// One tile: `height` rows of `width` palette indices, each 0...3.
    public struct Tile: Sendable {
        public let address: Int
        /// Water animates from a RAM buffer rather than a stored pattern, so
        /// there is nothing to read and it is drawn as flat color.
        public let isAnimated: Bool
        public let pixels: [[UInt8]]
    }

    /// The multicolor palette the exploration view runs, as C64 color indices.
    ///
    /// From the setup at `$32C0` and the raster interrupt at `$2250` that
    /// copies the shadow bytes into the VIC registers.
    public struct Palette: Sendable {
        public let land: Int        // $D021, bit pair 00
        public let water: Int       // $D022, bit pair 01
        public let vegetation: Int  // $D023, bit pair 10
        public let detail: Int      // color RAM & $07, bit pair 11
    }

    public static let palette = Palette(land: 0x07, water: 0x0E,
                                        vegetation: 0x05, detail: 0x00)

    public let tiles: [Terrain: Tile]

    public enum ExtractError: Error, CustomStringConvertible {
        case gameFileMissing
        case unexpectedLoadAddress(Int)
        case truncated

        public var description: String {
            switch self {
            case .gameFileMissing:
                "no file named 'game' on this disk — is it side 1?"
            case .unexpectedLoadAddress(let a):
                String(format: "'game' loads at $%04X, expected $0800", a)
            case .truncated:
                "'game' is too short to hold the terrain patterns"
            }
        }
    }

    /// Reads the tiles from side 1 of the program disk.
    public init(programDisk disk: DiskImage) throws {
        guard let file = disk.fileContents(named: "game") else {
            throw ExtractError.gameFileMissing
        }
        guard file.loadAddress == Self.loadAddress else {
            throw ExtractError.unexpectedLoadAddress(file.loadAddress)
        }
        let program = GameCipher.decrypt(file.bytes)

        let table = Self.terrainDispatch - Self.loadAddress
        guard program.count > table + 32 else { throw ExtractError.truncated }

        var out: [Terrain: Tile] = [:]
        for terrain in Terrain.allCases {
            let i = table + Int(terrain.rawValue) * 2
            let address = Int(program[i]) | Int(program[i + 1]) << 8
            let offset = address - Self.loadAddress
            // Water points into RAM the game animates, so there is no pattern
            // to read; anything out of range is treated the same way.
            guard offset >= 0, offset + Self.bytesPerTile <= program.count,
                  address < 0x9000
            else {
                out[terrain] = Tile(address: address, isAnimated: true,
                                    pixels: Self.flat(1))
                continue
            }
            out[terrain] = Tile(address: address, isAnimated: false,
                                pixels: Self.unpack(program, at: offset))
        }
        self.tiles = out
    }

    private static func flat(_ value: UInt8) -> [[UInt8]] {
        Array(repeating: Array(repeating: value, count: width), count: height)
    }

    /// Unpacks 32 bytes into a 2x2 block of characters.
    ///
    /// The four glyphs follow the video matrix layout the composer writes,
    /// `code = $70 + row + col * $0C` — down the left column first, then down
    /// the right — so glyph *g* sits at column `g / 2`, row `g % 2`.
    private static func unpack(_ program: [UInt8], at offset: Int) -> [[UInt8]] {
        var rows = flat(0)
        for g in 0..<4 {
            let col = g / 2, row = g % 2
            for y in 0..<8 {
                let byte = program[offset + g * 8 + y]
                for p in 0..<4 {
                    rows[row * 8 + y][col * 4 + p] = (byte >> (6 - p * 2)) & 3
                }
            }
        }
        return rows
    }
}
