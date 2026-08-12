import AppKit
import Foundation
import SevenCitiesCore
import SpriteKit

/// The original's terrain art, read out of the game's own program.
///
/// Produced by the extractor from *your* disk images into `assets/`, and loaded
/// at runtime rather than compiled in — these are the original's pixels and must
/// not ship with the engine. If the file is absent the viewer falls back to the
/// custom tiles and says so.
///
/// A tile is 2x2 of the original's characters: 8 multicolor pixels across by 16
/// rows down. Multicolor pixels are double-width, so a tile draws as a 16x16
/// square. See `TerrainTiles` for where this comes from.
struct OriginalTiles {

    struct Palette: Decodable {
        let land: Int
        let water: Int
        let vegetation: Int
        let detail: Int
    }

    struct Tile: Decodable {
        let address: Int
        let animated: Bool
        let pixels: [[UInt8]]
    }

    let palette: Palette
    let width: Int
    let height: Int
    let tiles: [String: Tile]

    /// The C64 hardware palette, in the usual VICE rendering.
    static let c64: [NSColor] = [
        (0, 0, 0), (255, 255, 255), (129, 51, 44), (112, 190, 196),
        (132, 60, 142), (85, 160, 73), (56, 45, 131), (206, 215, 118),
        (140, 90, 39), (87, 66, 0), (180, 102, 95), (78, 78, 78),
        (120, 120, 120), (154, 226, 142), (108, 94, 181), (149, 149, 149),
    ].map { NSColor(srgbRed: $0.0 / 255, green: $0.1 / 255, blue: $0.2 / 255, alpha: 1) }

    static func load(nextTo mapURL: URL) -> OriginalTiles? {
        let url = mapURL.deletingLastPathComponent()
            .appendingPathComponent("original_tiles.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        struct Wire: Decodable {
            let palette: Palette
            let width: Int
            let height: Int
            let tiles: [String: Tile]
        }
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return OriginalTiles(palette: w.palette, width: w.width,
                             height: w.height, tiles: w.tiles)
    }

    /// Tiles drawn from a stored pattern, as opposed to the water the original
    /// animates out of a RAM buffer and which we render as flat color.
    var patternCount: Int { tiles.values.filter { !$0.animated }.count }

    func texture(for terrain: Terrain, scale: Int = 4) -> SKTexture? {
        guard let tile = tiles[String(describing: terrain)],
              tile.pixels.count == height
        else { return nil }

        let pal = [
            Self.c64[palette.land], Self.c64[palette.water],
            Self.c64[palette.vegetation], Self.c64[palette.detail],
        ]
        // Multicolor pixels are double-width, so 8 across becomes 16 and the
        // tile comes out square.
        let w = width * 2 * scale, h = height * scale
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        for y in 0..<height {
            let row = tile.pixels[y]
            guard row.count == width else { return nil }
            for x in 0..<width {
                ctx.setFillColor(pal[Int(row[x]) & 3].cgColor)
                ctx.fill(CGRect(x: CGFloat(x * 2 * scale),
                                y: CGFloat((height - 1 - y) * scale),
                                width: CGFloat(2 * scale),
                                height: CGFloat(scale)))
            }
        }
        guard let cg = ctx.makeImage() else { return nil }
        let tex = SKTexture(cgImage: cg)
        tex.filteringMode = .nearest
        return tex
    }
}

public enum TileStyle: String, CaseIterable {
    case original = "Original (C64)"
    case custom = "Custom"
}
