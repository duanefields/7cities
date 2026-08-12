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
        /// `variantIndex[(y & 3) * 4 + (x & 3)]` selects from `variants`.
        let variantIndex: [Int]
        let variants: [[[UInt8]]]

        func pixels(x: Int, y: Int) -> [[UInt8]] {
            let i = variantIndex[((y % 4 + 4) % 4) * 4 + ((x % 4 + 4) % 4)]
            return variants[min(i, variants.count - 1)]
        }
    }

    let palette: Palette
    let width: Int
    let height: Int
    let tiles: [String: Tile]

    /// Which rendering of the C64's 16 colours to use.
    ///
    /// There is no single right answer, which is why this went back and forth
    /// three times before becoming a setting. The hardware emits a composite
    /// signal, not RGB, so every palette is a model of it: Pepto and Colodore
    /// are attempts at physical accuracy, while VICE's default — confusingly
    /// named "internal" — is a vivid approximation. Comparing against a VICE
    /// screenshot therefore measures whichever palette VICE was set to, not the
    /// machine.
    public enum C64Palette: String, CaseIterable, Sendable {
        case viceInternal = "VICE (internal)"
        case pepto = "Pepto (PAL)"
        case colodore = "Colodore"

        var colors: [(Int, Int, Int)] {
            switch self {
            // Measured from a native VICE screenshot, which has no CRT filter
            // and held exactly five colours, so these four are exact for it.
            case .viceInternal: [
                (3, 3, 3), (255, 255, 255), (104, 55, 43), (112, 164, 178),
                (111, 61, 134), (101, 216, 53), (53, 40, 121), (255, 255, 73),
                (111, 79, 37), (67, 57, 0), (154, 103, 89), (68, 68, 68),
                (108, 108, 108), (154, 210, 132), (118, 136, 255), (149, 149, 149),
            ]
            case .pepto: [
                (0, 0, 0), (255, 255, 255), (104, 55, 43), (112, 164, 178),
                (111, 61, 134), (88, 141, 67), (53, 40, 121), (184, 199, 111),
                (111, 79, 37), (67, 57, 0), (154, 103, 89), (68, 68, 68),
                (108, 108, 108), (154, 210, 132), (108, 94, 181), (149, 149, 149),
            ]
            case .colodore: [
                (0, 0, 0), (255, 255, 255), (129, 51, 56), (117, 206, 200),
                (142, 60, 151), (86, 172, 77), (46, 44, 155), (237, 241, 113),
                (142, 80, 41), (85, 56, 0), (196, 108, 113), (74, 74, 74),
                (123, 123, 123), (169, 255, 159), (112, 109, 235), (178, 178, 178),
            ]
            }
        }
    }

    /// The palette the viewer draws with. Defaults to VICE's own default, since
    /// that is what a screenshot from an unconfigured emulator shows.
    nonisolated(unsafe) public static var palette: C64Palette = .viceInternal

    static var c64: [NSColor] {
        palette.colors.map {
            NSColor(srgbRed: CGFloat($0.0) / 255, green: CGFloat($0.1) / 255,
                    blue: CGFloat($0.2) / 255, alpha: 1)
        }
    }

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

    /// How many distinct appearances the art actually contains.
    var variantCount: Int { tiles.values.reduce(0) { $0 + $1.variants.count } }

    func texture(for terrain: Terrain, x: Int = 0, y: Int = 0,
                 scale: Int = 4) -> SKTexture? {
        guard let tile = tiles[String(describing: terrain)] else { return nil }
        let pixels = tile.pixels(x: x, y: y)
        guard pixels.count == height else { return nil }

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
            let row = pixels[y]
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
        // Nearest keeps the pixels crisp when magnified, which is the point of
        // showing the original art at all. Mipmaps stop it falling apart in the
        // band just above the overview threshold, where it is still minified.
        tex.filteringMode = .nearest
        tex.usesMipmaps = true
        return tex
    }
}

public enum TileStyle: String, CaseIterable {
    case original = "Original (C64)"
    case custom = "Custom"
}
