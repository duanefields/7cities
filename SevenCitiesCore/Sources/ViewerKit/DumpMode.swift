import AppKit
import Foundation
import SevenCitiesCore

/// Headless verification: render the tileset and a slice of the world to PNG.
///
/// The viewer once came up as bare background with only the explorer visible,
/// and there was no way to inspect it without a screen. This renders through
/// the same texture path so a broken tile pipeline is visible in a file.
@MainActor
public enum DumpMode {

    public static func run(assetDirectory: URL, mapFile: String, style: TileStyle,
                    out: URL, generateSeed: UInt16? = nil) -> Int32 {
        let mapURL = assetDirectory.appendingPathComponent(mapFile)
        let loaded: WorldMap?
        if let seed = generateSeed {
            var g = WorldGenerator(seed: seed)
            loaded = g.generate()
        } else {
            loaded = try? WorldMap(contentsOf: mapURL)
        }
        guard let map = loaded else {
            FileHandle.standardError.write(Data("cannot load \(mapURL.path)\n".utf8))
            return 1
        }
        let originals = OriginalTiles.load(nextTo: mapURL)

        func texture(_ t: Terrain) -> CGImage? {
            if style == .original, let tex = originals?.texture(for: t) {
                return tex.cgImage()
            }
            return TileArt.texture(for: t).cgImage()
        }

        let tile = generateSeed == nil ? 16 : 4
        let cols = generateSeed == nil ? 64 : map.width
        let rows = generateSeed == nil ? 64 : map.height
        let startX = max(0, map.width / 2 - cols / 2)
        let startY = max(0, map.height / 2 - rows / 2)
        let w = cols * tile, h = (rows + 2) * tile

        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        var blank = 0
        for (i, t) in Terrain.allCases.enumerated() {
            guard let img = texture(t) else { blank += 1; continue }
            ctx.draw(img, in: CGRect(x: i * tile * 2, y: h - tile * 2,
                                     width: tile * 2, height: tile * 2))
        }
        for r in 0..<rows {
            for c in 0..<cols {
                let t = map[startX + c, startY + r]
                guard let img = texture(t) else { continue }
                ctx.draw(img, in: CGRect(x: c * tile,
                                         y: (rows - 1 - r) * tile,
                                         width: tile, height: tile))
            }
        }
        guard let cg = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                out as CFURL, "public.png" as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        print("dumped \(out.path): tileset strip + \(cols)x\(rows) of "
              + "\(mapFile) at (\(startX),\(startY)), style=\(style.rawValue)"
              + (blank > 0 ? "  WARNING \(blank) tiles had no texture" : ""))
        return 0
    }
}
