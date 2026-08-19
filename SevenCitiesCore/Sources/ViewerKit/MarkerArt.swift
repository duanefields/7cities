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
/// other 127 were bare, and diffing both charset buffers across a voyage shows
/// those bytes moving, so the specks travel.
///
/// A pair is two pixels wide and one tall, and `$D021` in the map region is
/// yellow — measured at 176 pixels of it against 8,800 of water.
enum SeaArt {

    /// How many distinct wave tiles to build. Each gets its speck in a different
    /// place and starts at a different point in the cycle, so the sea twinkles
    /// rather than blinking in unison.
    static let variants = 8
    /// Frames in one tile's cycle. Only one carries a speck, which is what keeps
    /// the sea mostly bare the way the original's is.
    static let frames = 6

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

    /// The frames of one wave variant: bare water except for a single frame.
    static func cycle(variant: Int, water: NSColor, speck: NSColor,
                      scale: Int) -> [SKTexture] {
        let bare = tile(speckAt: nil, water: water, speck: speck, scale: scale)
        // Spread the specks over the tile and the cycle so no two variants
        // twinkle together.
        let at = (x: (variant * 3) % 8, y: (variant * 5 + 1) % 16)
        let lit = tile(speckAt: at, water: water, speck: speck, scale: scale)
        return (0..<frames).map { $0 == variant % frames ? (lit ?? bare) : bare }
            .compactMap { $0 }
    }

    /// Which variant a position uses. Deterministic, so the sea does not change
    /// its pattern when the view is rebuilt.
    static func variant(x: Int, y: Int) -> Int {
        let n = (x &* 7) &+ (y &* 13)
        return ((n % variants) + variants) % variants
    }
}
