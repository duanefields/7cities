import AppKit
import SevenCitiesCore
import SpriteKit

/// Tiles drawn from scratch rather than lifted from the original.
///
/// The original composes its exploration view procedurally into redefined
/// characters, so there is no tile atlas to extract — and at native resolution
/// we would not want 8x8 multicolor art anyway. These are drawn to read
/// clearly when zoomed out to the whole 256x400 world and still hold up close.
enum TileArt {

    static let size: CGFloat = 32

    // A palette that keeps the original's reading of the world — three water
    // depths, land, vegetation — without copying its four-color constraint.
    private static let deep = NSColor(srgbRed: 0.05, green: 0.13, blue: 0.36, alpha: 1)
    private static let medium = NSColor(srgbRed: 0.10, green: 0.24, blue: 0.53, alpha: 1)
    private static let shallow = NSColor(srgbRed: 0.20, green: 0.45, blue: 0.68, alpha: 1)
    private static let river = NSColor(srgbRed: 0.32, green: 0.62, blue: 0.85, alpha: 1)
    private static let grass = NSColor(srgbRed: 0.42, green: 0.60, blue: 0.29, alpha: 1)
    private static let wood = NSColor(srgbRed: 0.20, green: 0.38, blue: 0.20, alpha: 1)
    private static let bog = NSColor(srgbRed: 0.36, green: 0.44, blue: 0.26, alpha: 1)
    private static let rock = NSColor(srgbRed: 0.47, green: 0.43, blue: 0.38, alpha: 1)
    private static let snow = NSColor(srgbRed: 0.85, green: 0.86, blue: 0.87, alpha: 1)
    private static let hut = NSColor(srgbRed: 0.62, green: 0.36, blue: 0.20, alpha: 1)
    private static let timber = NSColor(srgbRed: 0.30, green: 0.20, blue: 0.12, alpha: 1)

    /// Deterministic jitter so texture does not shimmer between redraws.
    private static func rng(_ seed: Int) -> () -> CGFloat {
        var s = UInt64(truncatingIfNeeded: seed &* 2_654_435_761 &+ 1)
        return {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return CGFloat(s % 1000) / 1000.0
        }
    }

    /// A single flat colour per terrain, for the zoomed-out overview.
    ///
    /// Detailed art cannot survive being drawn a few pixels wide — the useful
    /// thing at that scale is the shape of the coast, the rivers and the
    /// mountain ranges, not individual trees. Colours are the original's own
    /// multicolour palette, so the overview still reads as the same world.
    static func flatTexture(for terrain: Terrain) -> SKTexture {
        if let cached = flatCache[terrain] { return cached }
        let c64 = OriginalTiles.c64
        let color: NSColor = switch terrain {
        case .deepWater, .mediumWater, .shallowWater, .ship: c64[0x0E]
        case .riverJunction, .riverWE, .riverNW, .riverSW,
             .riverNS, .riverNE, .riverSE: c64[0x0E].blended(withFraction: 0.25, of: c64[0x07]) ?? c64[0x0E]
        case .plain: c64[0x07]
        case .forest, .swamp: c64[0x05]
        case .mountain: c64[0x00]
        case .village: c64[0x02]
        }
        let side = 8
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        image.unlockFocus()
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return texture(for: terrain)
        }
        let tex = SKTexture(cgImage: cg)
        tex.filteringMode = .nearest
        flatCache[terrain] = tex
        return tex
    }

    nonisolated(unsafe) private static var flatCache: [Terrain: SKTexture] = [:]

    static func texture(for terrain: Terrain) -> SKTexture {
        // Draw into a bitmap context and build the texture from the finished
        // CGImage. Creating an SKTexture from an NSImage that is still
        // lockFocus'd yields an empty texture — the map renders as nothing but
        // background, which is exactly how this first failed.
        let px = Int(size)
        guard let ctx = CGContext(
            data: nil, width: px, height: px, bitsPerComponent: 8,
            bytesPerRow: px * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return SKTexture() }

        draw(terrain, in: ctx)

        guard let cg = ctx.makeImage() else { return SKTexture() }
        let tex = SKTexture(cgImage: cg)
        tex.filteringMode = .nearest
        return tex
    }

    private static func fill(_ ctx: CGContext, _ color: NSColor) {
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }

    private static func speckle(_ ctx: CGContext, _ color: NSColor,
                                count: Int, radius: CGFloat, seed: Int) {
        let next = rng(seed)
        ctx.setFillColor(color.cgColor)
        for _ in 0..<count {
            let x = next() * size, y = next() * size
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: radius, height: radius))
        }
    }

    private static func draw(_ terrain: Terrain, in ctx: CGContext) {
        switch terrain {
        case .deepWater:
            fill(ctx, deep)
        case .mediumWater:
            fill(ctx, medium)
        case .shallowWater:
            fill(ctx, shallow)
            speckle(ctx, medium, count: 6, radius: 3, seed: 2)

        case .plain:
            fill(ctx, grass)
            speckle(ctx, wood.withAlphaComponent(0.20), count: 10, radius: 2, seed: 11)

        case .forest:
            fill(ctx, grass)
            let next = rng(12)
            for _ in 0..<7 {
                let x = next() * (size - 8) + 2, y = next() * (size - 10) + 2
                ctx.setFillColor(timber.cgColor)
                ctx.fill(CGRect(x: x + 2.5, y: y, width: 2, height: 4))
                ctx.setFillColor(wood.cgColor)
                ctx.fillEllipse(in: CGRect(x: x, y: y + 3, width: 8, height: 7))
            }

        case .swamp:
            fill(ctx, bog)
            ctx.setStrokeColor(river.withAlphaComponent(0.75).cgColor)
            ctx.setLineWidth(2)
            let next = rng(13)
            for _ in 0..<5 {
                let y = next() * size
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: size, y: y + next() * 3 - 1.5))
                ctx.strokePath()
            }
            speckle(ctx, wood, count: 5, radius: 4, seed: 14)

        case .mountain:
            fill(ctx, grass)
            ctx.setFillColor(rock.cgColor)
            ctx.move(to: CGPoint(x: 2, y: 4))
            ctx.addLine(to: CGPoint(x: size / 2, y: size - 3))
            ctx.addLine(to: CGPoint(x: size - 2, y: 4))
            ctx.closePath()
            ctx.fillPath()
            ctx.setFillColor(snow.cgColor)
            ctx.move(to: CGPoint(x: size / 2 - 5, y: size - 11))
            ctx.addLine(to: CGPoint(x: size / 2, y: size - 3))
            ctx.addLine(to: CGPoint(x: size / 2 + 5, y: size - 11))
            ctx.closePath()
            ctx.fillPath()

        case .village:
            fill(ctx, grass)
            ctx.setFillColor(hut.cgColor)
            ctx.fill(CGRect(x: 8, y: 8, width: 16, height: 11))
            ctx.setFillColor(timber.cgColor)
            ctx.move(to: CGPoint(x: 6, y: 19))
            ctx.addLine(to: CGPoint(x: size / 2, y: 27))
            ctx.addLine(to: CGPoint(x: 26, y: 19))
            ctx.closePath()
            ctx.fillPath()

        case .ship:
            fill(ctx, medium)
            ctx.setFillColor(timber.cgColor)
            ctx.fill(CGRect(x: 5, y: 10, width: 22, height: 6))
            ctx.fill(CGRect(x: 15, y: 16, width: 2, height: 10))
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 17, y: 18, width: 8, height: 7))

        case .riverJunction, .riverWE, .riverNW, .riverSW,
             .riverNS, .riverNE, .riverSE:
            drawRiver(terrain, in: ctx)
        }
    }

    /// Rivers are drawn from their connection mask, so a channel always meets
    /// its neighbours' channels exactly.
    private static func drawRiver(_ terrain: Terrain, in ctx: CGContext) {
        fill(ctx, grass)
        ctx.setFillColor(river.cgColor)
        let w: CGFloat = 10
        let mid = (size - w) / 2
        ctx.fill(CGRect(x: mid, y: mid, width: w, height: w))     // centre
        for d in terrain.riverConnections {
            switch d {
            case .north: ctx.fill(CGRect(x: mid, y: mid, width: w, height: size - mid))
            case .south: ctx.fill(CGRect(x: mid, y: 0, width: w, height: mid + w))
            case .east: ctx.fill(CGRect(x: mid, y: mid, width: size - mid, height: w))
            case .west: ctx.fill(CGRect(x: 0, y: mid, width: mid + w, height: w))
            }
        }
    }
}
