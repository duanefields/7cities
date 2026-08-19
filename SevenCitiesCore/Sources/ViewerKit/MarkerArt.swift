import AppKit
import SpriteKit

/// The expedition's marker, and the pip that shows its bearing.
///
/// Drawn here rather than extracted: the originals are hardware sprites whose
/// bitmaps live in RAM at runtime with no known source on disk. These follow the
/// structure captured from a live game — shape, thickness, size and color — but
/// are constructed rather than copied.
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

    /// The ring — and the landing party, which is the **same sprite**.
    ///
    /// Captured both at sea and ashore: sprite 1, pointer `$2D`, identical seven
    /// bytes either way. There is no separate party sprite, which is why none was
    /// ever found; aboard or ashore the expedition is this ring, and only the
    /// bearing pip on it changes.
    ///
    /// Eight pixels wide and seven tall with **two-pixel-thick** edges, and both
    /// sprites are hardware-expanded in x and y (`$D01D` = `$D017` = `03`), so it
    /// draws at 16x14 — about one map tile across. An earlier version was 11x11
    /// with single-pixel edges and read thin and spindly beside the original.
    /// Seven wide, not eight. The sprite byte is eight bits but the shape sits in
    /// columns 0-6 with the last blank, so a pattern padded to eight puts the
    /// ring half a pixel left of its node's center while the pip sits exactly on
    /// it — and the needle then reads off-axis, most visibly due north. Trimmed
    /// to seven, both are 7x7 and concentric.
    static let ring = [
        "..###..",
        ".##.##.",
        "##...##",
        "#.....#",
        "##...##",
        ".##.##.",
        "..###..",
    ]

    /// The bearing: a needle sitting on the rim, its stem running inward.
    ///
    /// Sprite 0, three or four bytes, rewritten in place rather than swapped by
    /// pointer, and drawn in `$D027` = `$2` red against the ring's `$D028` = `$1`
    /// white. It is absent entirely while the expedition is not moving.
    ///
    /// Not a symmetric plus: one arm runs longer, back toward the middle of the
    /// ring, so the mark reads as a needle rather than a crosshair. Built
    /// geometrically rather than as eight hand-drawn patterns, because the
    /// diagonals have to work too — a plus with a diagonal tail drawn by hand
    /// looked wrong in every one of them. The stem runs inward from the rim and
    /// the short bar crosses it perpendicular at the outer end, so all eight
    /// directions come out of the same construction.
    static func pip(dx: Int, dy: Int) -> [String] {
        let n = 9, c = 4
        var g = Array(repeating: Array(repeating: Character("."), count: n), count: n)
        func plot(_ col: Int, _ row: Int) {
            guard (0..<n).contains(col), (0..<n).contains(row) else { return }
            g[row][col] = "#"
        }
        // Inward, toward the ring's center. Pattern rows count downward the same
        // way map rows do, so this is simply the negated step.
        let ix = -dx, iy = -dy
        // The stem runs from one cell *outside* the bar to three inside it. That
        // stub on the outer side is what makes it a cross rather than a T — with
        // the bar at the very tip it reads as one, which is what the first
        // version drew.
        for k in -1...3 { plot(c + ix * k, c + iy * k) }
        // The short bar, perpendicular, crossing the stem rather than capping it.
        for s in [-1, 1] { plot(c - iy * s, c + ix * s) }
        return g.map { String($0) }
    }

    /// Where the needle sits, as a fraction of the ring's radius: on the rim.
    ///
    /// The diamond's rim is closer to the middle along a diagonal than along an
    /// axis — its corners reach the radius, its flats do not — so the diagonals
    /// take a smaller step in each axis or the needle floats off the ring.
    static func pipOffset(dx: Int, dy: Int) -> CGPoint {
        let diagonal = dx != 0 && dy != 0
        let k: CGFloat = diagonal ? 0.42 : 0.8
        // SpriteKit's y runs up; a step "north" is -1 in map rows.
        return CGPoint(x: CGFloat(dx) * k, y: CGFloat(-dy) * k)
    }
}

/// The sea, which the original draws flat and then stipples.
///
/// There is no wave art anywhere — the tile buffers the `$5529` table points at
/// hold a uniform `$55`, every bit-pair `01`, which is solid `$D022`. A wave is
/// instead one **pixel-pair** zeroed inside an otherwise-uniform water byte, so
/// it draws in `$D021`: measured `$54`, `$51` and `$45` against `$55`, and
/// `$D021` in the map region is yellow.
///
/// ## Density
///
/// Measured on a live frame: **12 specks among 70 water glyphs**, so about 0.17
/// a glyph. A tile is four glyphs, which puts it near **0.7 specks per tile** —
/// dense enough that most tiles carry one. An earlier version stippled one tile
/// in eight and the sea read far too empty.
///
/// ## They do not move
///
/// Sampling the charset while the ship was stationary gave the same specks in the
/// same places over three seconds. A diff across twenty *moves* does show them
/// changing, but that is the view scrolling a different piece of sea under a
/// fixed stipple. So a tile's specks are a pure function of its map position, and
/// the sea appears to move only because you do.
enum SeaArt {

    /// How many distinct wave tiles to build. Bounded so the tile set stays
    /// small; which one a position uses is a hash, so the pattern never shuffles.
    static let appearances = 48

    /// The specks on one appearance: up to one per quadrant of the tile, each
    /// present at roughly the measured rate.
    static func specks(_ variant: Int) -> [(x: Int, y: Int)] {
        var out: [(x: Int, y: Int)] = []
        for quadrant in 0..<4 {
            var h = (variant &* 2_654_435_761) ^ (quadrant &* 40_503)
            h = abs((h ^ (h >> 11)) &* 668_265_263)
            guard h % 100 < 17 else { continue }        // 0.17 a glyph, measured
            // A tile is 8 pixel-pairs across and 16 rows; a quadrant is half of
            // each.
            let qx = (quadrant % 2) * 4, qy = (quadrant / 2) * 8
            out.append((x: qx + (h / 100) % 4, y: qy + (h / 400) % 8))
        }
        return out
    }

    /// Which appearance a map position uses.
    static func variant(x: Int, y: Int) -> Int {
        var h = (x &* 73_856_093) ^ (y &* 19_349_663)
        h = abs((h ^ (h >> 13)) &* 1_274_126_177)
        return h % appearances
    }

    /// One 16x16 tile: flat water, stippled with its specks.
    static func tile(specks: [(x: Int, y: Int)], water: NSColor, speck: NSColor,
                     scale: Int) -> SKTexture? {
        let side = 16 * scale
        guard let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(water.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.setFillColor(speck.cgColor)
        for p in specks {
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
