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
    /// 64 motif indices, read as `[(y & 3) * 4 + (x & 3)] * 4`, used by forest
    /// and swamp to permute four motifs between the tile's four characters.
    public static let motifTable = 0x54E9
    /// `00 24 48 6C`, the mountain variant shifts.
    public static let variantOffsets = 0x58B4
    /// `game` loads here, so a pattern address minus this is a file offset.
    public static let loadAddress = 0x0800
    public static let bytesPerTile = 32
    public static let width = 8
    public static let height = 16

    /// One tile. Terrain is drawn **from the tile's map position**, not from a
    /// single fixed bitmap, so a tile carries every variant it can take plus the
    /// rule for choosing between them.
    ///
    /// - mountain shifts its source pointer by `(x & 3) + T[x & 1] + T[y & 1]`,
    ///   which is what makes peaks join into ranges instead of repeating.
    /// - forest and swamp permute four motifs between the tile's four
    ///   characters, so a wood reads as many individual trees.
    /// - everything else has a single variant.
    public struct Tile: Sendable {
        public let address: Int
        /// Water animates from a RAM buffer rather than a stored pattern, so
        /// there is nothing to read and it is drawn as flat color.
        public let isAnimated: Bool
        /// Distinct appearances, in no particular order.
        public let variants: [[[UInt8]]]
        /// `variantIndex[(y & 3) * 4 + (x & 3)]` selects from `variants`.
        public let variantIndex: [Int]

        /// The variant for a map position.
        public func pixels(x: Int, y: Int) -> [[UInt8]] {
            variants[variantIndex[(y & 3) * 4 + (x & 3)]]
        }

        /// The representative appearance, for a legend or a tile strip.
        public var pixels: [[UInt8]] { variants[variantIndex[0]] }
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

        // Composer tables, read from the program rather than hard-coded.
        let motifTable = Self.motifTable - Self.loadAddress
        let variantOffsets = Self.variantOffsets - Self.loadAddress
        guard program.count > motifTable + 64,
              program.count > variantOffsets + 4 else { throw ExtractError.truncated }

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
                                    variants: [Self.flat(1)],
                                    variantIndex: Array(repeating: 0, count: 16))
                continue
            }

            var variants: [[[UInt8]]] = []
            var index = [Int](repeating: 0, count: 16)
            var seen: [String: Int] = [:]
            for cell in 0..<16 {
                let x = cell % 4, y = cell / 4
                let pixels: [[UInt8]]
                switch terrain {
                case .forest, .swamp:
                    pixels = Self.compose(program, at: offset, x: x, y: y,
                                          motifTable: motifTable)
                case .mountain:
                    let t = [0, Int(program[variantOffsets + 1])]   // 0 and $24
                    let shift = (x & 3) + t[x & 1] + t[y & 1]
                    let o = offset + shift
                    pixels = o + Self.bytesPerTile <= program.count
                        ? Self.unpack(program, at: o) : Self.unpack(program, at: offset)
                default:
                    pixels = Self.unpack(program, at: offset)
                }
                let key = pixels.map { $0.map(String.init).joined() }.joined(separator: "|")
                if let existing = seen[key] {
                    index[cell] = existing
                } else {
                    seen[key] = variants.count
                    index[cell] = variants.count
                    variants.append(pixels)
                }
            }
            out[terrain] = Tile(address: address, isAnimated: false,
                                variants: variants, variantIndex: index)
        }
        self.tiles = out
    }

    private static func flat(_ value: UInt8) -> [[UInt8]] {
        Array(repeating: Array(repeating: value, count: width), count: height)
    }

    /// Forest and swamp: four motifs of eight bytes, permuted between the
    /// tile's four characters according to the tile's position.
    ///
    /// The original writes each motif to a destination picked from a table of
    /// character offsets — `$0000`, `$0060`, `$0068`, `$0008`, which are exactly
    /// top-left, top-right, bottom-right and bottom-left of the 2x2 block.
    private static func compose(_ program: [UInt8], at offset: Int,
                                x: Int, y: Int, motifTable: Int) -> [[UInt8]] {
        // motif value -> (column, row) within the 2x2 block
        let quadrant: [(Int, Int)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
        var rows = flat(0)
        let cell = ((y & 3) * 4 + (x & 3)) * 4
        for i in 0..<4 {
            let v = Int(program[motifTable + cell + i]) & 3
            let (col, row) = quadrant[v]
            for yy in 0..<8 {
                let byte = program[offset + i * 8 + yy]
                for p in 0..<4 {
                    rows[row * 8 + yy][col * 4 + p] = (byte >> (6 - p * 2)) & 3
                }
            }
        }
        return rows
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
