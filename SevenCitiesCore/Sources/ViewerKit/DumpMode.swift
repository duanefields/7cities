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
            // Configuration 0 rather than a draw, so a dump of a given seed is
            // the same picture every time.
            loaded = (try? WorldMaker.world(config: 0, seed: seed))
                .map(WorldMap.init)
        } else {
            loaded = try? WorldMap(contentsOf: mapURL)
        }
        guard let map = loaded else {
            FileHandle.standardError.write(Data("cannot load \(mapURL.path)\n".utf8))
            return 1
        }
        let originals = OriginalTiles.load(nextTo: mapURL)

        // Must pass the map position: terrain is drawn per position, and a
        // dump that always used variant 0 verified a path the viewer does not
        // take, which is how a broken detail layer got shipped twice.
        // `SKTexture.cgImage()` rasterises, and `OriginalTiles` rebuilds the
        // texture from pixels on every call — so a generated dump asks for a
        // hundred thousand of them and takes minutes. Memoise.
        //
        // The key has to be what the tile *is*, not the texture's identity:
        // `ObjectIdentifier` is only unique while the object lives, these are
        // released as soon as the image is taken, and a cache keyed on identity
        // hands the first tile's image back for everything that lands on the
        // same freed address. That rendered the whole map as ocean.
        //
        // `Tile.pixels(x:y:)` picks its variant from `(x % 4, y % 4)` and
        // nothing else, so terrain plus that pair names the tile exactly —
        // sixteen terrains by sixteen positions, two hundred and fifty-six
        // images at most.
        struct TileKey: Hashable { let terrain: Terrain, x: Int, y: Int }
        var images: [TileKey: CGImage?] = [:]
        func texture(_ t: Terrain, _ x: Int = 0, _ y: Int = 0) -> CGImage? {
            let key = TileKey(terrain: t, x: ((x % 4) + 4) % 4,
                              y: ((y % 4) + 4) % 4)
            if let hit = images[key] { return hit }
            let made: CGImage?
            if style == .original, let tex = originals?.texture(for: t, x: x, y: y) {
                made = tex.cgImage()
            } else {
                made = TileArt.texture(for: t).cgImage()
            }
            images[key] = made
            return made
        }

        let tile = generateSeed == nil ? 16 : 4
        let cols = generateSeed == nil ? 64 : map.width
        let rows = generateSeed == nil ? 64 : map.height
        // Allow aiming the dump, so a reported region can be reproduced.
        let env = ProcessInfo.processInfo.environment
        let startX = env["DUMP_X"].flatMap(Int.init) ?? max(0, map.width / 2 - cols / 2)
        let startY = env["DUMP_Y"].flatMap(Int.init) ?? max(0, map.height / 2 - rows / 2)
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
                guard let img = texture(t, startX + c, startY + r) else { continue }
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
