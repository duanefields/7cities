import AppKit
import Foundation
import SevenCitiesCore
import SpriteKit

/// The original's 8x8 multicolor terrain art, lifted from a captured frame.
///
/// Produced by `tools/extract_tiles.py` and loaded at runtime rather than
/// compiled in — these are the original's pixels and must not ship with the
/// engine. If the file is absent the viewer falls back to the custom tiles and
/// says so.
struct OriginalTiles {

    struct Palette: Decodable {
        let bg0_land: Int
        let bg1_water: Int
        let bg2_vegetation: Int
        let fg_detail: Int
    }

    let palette: Palette
    let tiles: [String: [UInt8]]
    let origin: [String: String]

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
            let tiles: [String: [UInt8]]
            let origin: [String: String]
        }
        guard let w = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        return OriginalTiles(palette: w.palette, tiles: w.tiles, origin: w.origin)
    }

    /// How many tiles are the original's own pixels rather than reconstructions.
    var capturedCount: Int { origin.values.filter { $0.hasPrefix("captured") }.count }

    func texture(for terrain: Terrain, scale: Int = 4) -> SKTexture? {
        guard let rows = tiles[String(describing: terrain)], rows.count == 8 else {
            return nil
        }
        let pal = [
            Self.c64[palette.bg0_land], Self.c64[palette.bg1_water],
            Self.c64[palette.bg2_vegetation], Self.c64[palette.fg_detail],
        ]
        // 4 double-width pixels per row, drawn square so tiles stay 1:1 on the map
        let side = 8 * scale
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        defer { image.unlockFocus() }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return nil }
        for y in 0..<8 {
            let bits = rows[y]
            for p in 0..<4 {
                let v = Int((bits >> (6 - p * 2)) & 3)
                ctx.setFillColor(pal[v].cgColor)
                ctx.fill(CGRect(x: CGFloat(p * 2 * scale),
                                y: CGFloat((7 - y) * scale),
                                width: CGFloat(2 * scale),
                                height: CGFloat(scale)))
            }
        }
        let tex = SKTexture(image: image)
        tex.filteringMode = .nearest
        return tex
    }
}

enum TileStyle: String, CaseIterable {
    case original = "Original (C64)"
    case custom = "Custom"
}
