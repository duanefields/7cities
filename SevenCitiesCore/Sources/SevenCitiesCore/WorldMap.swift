import Foundation

/// A decoded world: a flat grid of terrain tiles.
///
/// Produced by `tools/extract_map.py` from a map disk you own. The file format
/// is deliberately dumb — one tile per byte, row major — because the original's
/// packing (16x16 blocks, 8 blocks per row, split column halves, two tiles per
/// byte) is exactly the kind of thing that should be decoded once and never
/// again.
public struct WorldMap: Sendable {

    public let width: Int
    public let height: Int
    private let tiles: [Terrain]

    public enum LoadError: Error, CustomStringConvertible {
        case tooShort
        case badMagic
        case unsupportedVersion(UInt8)
        case sizeMismatch(expected: Int, got: Int)
        case badTerrainValue(UInt8)

        public var description: String {
            switch self {
            case .tooShort: "map file is too short to contain a header"
            case .badMagic: "not a 7CMP map file"
            case .unsupportedVersion(let v): "unsupported map version \(v)"
            case .sizeMismatch(let e, let g): "expected \(e) tiles, got \(g)"
            case .badTerrainValue(let v):
                "byte \(v) is not a terrain value (must be 0-15)"
            }
        }
    }

    /// A world the World Maker built.
    ///
    /// The pipeline works in nibbles and `Terrain` is that same vocabulary, so
    /// this is a reinterpretation rather than a translation. The one value that
    /// cannot appear is `$3` — `$2C14` puts it back to plain as the last thing
    /// it does — which is why `ship` never turns up in a generated world even
    /// though the historical map disk carries fourteen of them.
    public init(_ world: WorldMaker.World) {
        let rows = world.rows
        self.width = 256
        self.height = rows.count
        self.tiles = rows.flatMap { row in
            row.map { Terrain(rawValue: $0) ?? .deepWater }
        }
    }

    public init(width: Int, height: Int, tiles: [Terrain]) {
        precondition(tiles.count == width * height)
        self.width = width
        self.height = height
        self.tiles = tiles
    }

    public init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        guard data.count >= 9 else { throw LoadError.tooShort }
        let bytes = [UInt8](data)
        guard bytes[0] == 0x37, bytes[1] == 0x43,
              bytes[2] == 0x4D, bytes[3] == 0x50 else { throw LoadError.badMagic }
        let version = bytes[4]
        guard version == 1 else { throw LoadError.unsupportedVersion(version) }

        let w = Int(bytes[5]) | Int(bytes[6]) << 8
        let h = Int(bytes[7]) | Int(bytes[8]) << 8
        let payload = bytes[9...]
        guard payload.count == w * h else {
            throw LoadError.sizeMismatch(expected: w * h, got: payload.count)
        }

        var out = [Terrain]()
        out.reserveCapacity(w * h)
        for byte in payload {
            guard let t = Terrain(rawValue: byte) else {
                throw LoadError.badTerrainValue(byte)
            }
            out.append(t)
        }
        self.init(width: w, height: h, tiles: out)
    }

    /// Writes the flat 7CMP format the viewer reads.
    public func write(to url: URL) throws {
        var out = Data([0x37, 0x43, 0x4D, 0x50, 1])
        out.append(UInt8(width & 0xFF)); out.append(UInt8(width >> 8))
        out.append(UInt8(height & 0xFF)); out.append(UInt8(height >> 8))
        out.append(contentsOf: tiles.map(\.rawValue))
        try out.write(to: url)
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// The tile at a position. Off-map reads return deep water, so the edge of
    /// the world behaves like open ocean rather than trapping the player.
    public subscript(x: Int, y: Int) -> Terrain {
        guard contains(x: x, y: y) else { return .deepWater }
        return tiles[y * width + x]
    }

    public func neighbor(of x: Int, _ y: Int, _ d: Direction) -> Terrain {
        self[x + d.offset.dx, y + d.offset.dy]
    }

    /// A sensible place to drop the player in: a land tile near the middle of
    /// the landmass, preferring somewhere adjacent to water so the coastline
    /// is visible on arrival.
    public func suggestedStart() -> (x: Int, y: Int)? {
        var fallback: (Int, Int)?
        for y in stride(from: height / 4, to: height * 3 / 4, by: 1) {
            for x in stride(from: 0, to: width, by: 1) where self[x, y].isLand {
                if fallback == nil { fallback = (x, y) }
                let touchesWater = Direction.allCases.contains {
                    neighbor(of: x, y, $0).isWater
                }
                if touchesWater { return (x, y) }
            }
        }
        return fallback
    }
}
