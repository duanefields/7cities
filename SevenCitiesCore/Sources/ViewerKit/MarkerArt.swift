import AppKit
import SpriteKit

/// The two things the expedition is drawn as, and the pip that shows its
/// bearing. Drawn here rather than extracted.
///
/// The originals are hardware sprites, and their bitmaps live in RAM at runtime
/// with no known source on disk — so these are shapes of our own, built to the
/// structure captured from a live game rather than copied from it:
///
/// - **The compass** is two sprites at one position. Sprite 1 is a static ring,
///   a diamond *outline* with a hole in the middle. Sprite 0 is the bearing, and
///   it is not an arrow: three or four bytes forming a pip, rewritten in place
///   at whichever point of the rose is being steered toward, and left **empty**
///   while the expedition is not moving.
/// - **The party** was never captured — the quest it needed ended first — so it
///   is invented outright. `$5529` has no entry for one either.
enum MarkerArt {

    /// A texture from a pattern of `#` and anything else, one character a pixel.
    static func texture(_ rows: [String], color: NSColor) -> SKTexture? {
        let h = rows.count, w = rows.map(\.count).max() ?? 0
        guard w > 0, h > 0 else { return nil }
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(color.cgColor)
        for (y, row) in rows.enumerated() {
            for (x, c) in row.enumerated() where c == "#" {
                // The context is bottom-up; the pattern reads top-down.
                ctx.fill(CGRect(x: x, y: h - 1 - y, width: 1, height: 1))
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }

    /// The compass ring: a diamond outline, hollow, as the captured sprite is.
    static let compassRing = [
        ".....#.....",
        "....#.#....",
        "...#...#...",
        "..#.....#..",
        ".#.......#.",
        "#.........#",
        ".#.......#.",
        "..#.....#..",
        "...#...#...",
        "....#.#....",
        ".....#.....",
    ]

    /// The bearing pip, which sits on the ring at the point being steered to.
    static let compassPip = ["##", "##"]

    /// The landing party. Invented — see the note above.
    static let party = [
        "..###..",
        "..###..",
        "...#...",
        ".#####.",
        "...#...",
        "..#.#..",
        "..#.#..",
    ]

    /// Where the pip sits for a step, as a fraction of the ring's radius. The
    /// diagonals are pulled in so the pip stays on the ring rather than beyond
    /// its corners.
    static func pipOffset(dx: Int, dy: Int) -> CGPoint {
        let diagonal = dx != 0 && dy != 0
        let k: CGFloat = diagonal ? 0.5 : 1.0
        // SpriteKit's y runs up; a step "north" is -1 in map rows.
        return CGPoint(x: CGFloat(dx) * k, y: CGFloat(-dy) * k)
    }
}

/// The sea, which the original draws flat and then stipples.
///
/// There is no wave art anywhere — the tile buffers the `$5529` table points at
/// hold a uniform `$55`, every bit-pair `01`, which is solid `$D022`. A wave is
/// instead one **pixel-pair** zeroed inside an otherwise-uniform water byte, so
/// it draws in `$D021`: measured `$54`, `$51` and `$45` against `$55`. On one
/// captured frame 17 of the 144 terrain glyphs carried exactly one speck and the
/// other 127 were bare — about one tile in eight.
///
/// A pair is two pixels wide and one tall, and `$D021` in the map region is
/// yellow — measured at 176 pixels of it against 8,800 of water.
///
/// ## The specks do not animate
///
/// They are fixed to the world, not to the screen: sampling the charset while
/// the ship was stationary gave the same 17 specks in the same places across six
/// samples over three seconds. An earlier version of this had them twinkling,
/// from misreading a diff taken across twenty *moves* — that showed the stipple
/// changing only because the view had scrolled a different piece of sea under
/// it. So the speck a tile carries is a pure function of its map position and
/// nothing else, and the sea appears to move only because you do.
enum SeaArt {

    /// Where a tile's speck sits, or `nil` for the seven tiles in eight that
    /// carry none. A pure function of the map position, so the sea is painted on
    /// the world rather than on the screen.
    static func speck(x: Int, y: Int) -> (x: Int, y: Int)? {
        var h = (x &* 73_856_093) ^ (y &* 19_349_663)
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h = abs(h ^ (h >> 16))
        guard h % 8 == 0 else { return nil }          // ~1 tile in 8, as measured
        return (x: (h / 8) % 8, y: (h / 64) % 16)
    }

    /// The key for a tile's appearance: bare water, or water with its speck.
    static func variantKey(x: Int, y: Int) -> String {
        guard let s = speck(x: x, y: y) else { return "bare" }
        return "s\(s.x)_\(s.y)"
    }

    /// One 16x16 tile: flat water, optionally with a single two-by-one speck.
    static func tile(speckAt: (x: Int, y: Int)?, water: NSColor, speck: NSColor,
                     scale: Int) -> SKTexture? {
        let side = 16 * scale
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(water.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        if let p = speckAt {
            ctx.setFillColor(speck.cgColor)
            // A multicolor pair is two pixels wide; the context is bottom-up.
            ctx.fill(CGRect(x: p.x * 2 * scale, y: (15 - p.y) * scale,
                            width: 2 * scale, height: scale))
        }
        guard let image = ctx.makeImage() else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }
}
