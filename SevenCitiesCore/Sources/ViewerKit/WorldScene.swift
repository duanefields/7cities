import AppKit
import Foundation
import SevenCitiesCore
import SpriteKit

/// A scrollable, zoomable view of a decoded world, with a walkable explorer.
///
/// The whole 256x400 grid goes into one `SKTileMapNode`, which handles culling,
/// so zooming out to the entire world stays cheap.
final class WorldScene: SKScene {

    private let map: WorldMap
    private let style: TileStyle
    private let originals: OriginalTiles?
    private var tileMap: SKTileMapNode!
    private let cam = SKCameraNode()
    private let explorer = SKShapeNode(circleOfRadius: TileArt.size * 0.32)

    /// Called with the status text whenever it changes. The HUD lives in the
    /// window as an AppKit view rather than as a node, because anything
    /// parented to the camera inherits the camera transform and therefore
    /// shrinks, grows and drifts off-screen as you zoom.
    var onStatusChange: (@MainActor ([String]) -> Void)?

    private var position2D: (x: Int, y: Int)
    private var fog: FogOfWar
    private var fogNode: SKSpriteNode?

    /// Whether the fog is drawn at all.
    ///
    /// Off belongs with the classic aperture and nothing else. The original has
    /// no fog: its constraint is the *size of the hole*, not darkness, and every
    /// one of its thirty-six tiles is drawn. Switching the fog off without also
    /// shrinking the aperture shows far **more** than the C64 ever did, which is
    /// the opposite of faithful — an early version of this offered exactly that
    /// and called it the purist's setting.
    ///
    /// The fog *state* keeps running either way. It costs nothing to maintain,
    /// and the discovery screen's percentages are computed from it, so switching
    /// the drawing off must not stop the counting.
    var fogEnabled = true {
        didSet {
            fogNode?.isHidden = !fogEnabled
            if fogEnabled { updateFog() }
            refreshStatus()
        }
    }
    /// Reused between updates: one RGBA byte per map cell. Rebuilt on every step,
    /// so it is not worth reallocating 400 KB each time.
    private var fogPixels: [UInt8] = []
    /// Loose enough that the window shows well past the sight radius.
    ///
    /// This was 3.0, at which a viewport shows about five and a half tiles —
    /// entirely *inside* the seven-tile lit block, so every visible cell was
    /// `.visible`, nothing was ever dimmed, and the fog looked broken while
    /// working perfectly. An aperture tighter than its own sight radius cannot
    /// show fog by construction.
    static let defaultZoom: CGFloat = 1.0

    private var zoom: CGFloat = WorldScene.defaultZoom { didSet { applyZoom() } }

    /// Non-nil pins the view so exactly this many map tiles span its width, and
    /// takes the zoom controls away.
    ///
    /// This is what makes the classic aperture *be* six tiles rather than merely
    /// be drawn in a six-tile hole: the frame alone would leave whatever the
    /// zoom happened to be showing, which is any number of tiles but six.
    var lockedTilesAcross: Int? {
        didSet {
            // Releasing the lock has to put the zoom back, or the wide aperture
            // inherits whatever the classic one computed — which is tighter than
            // the sight radius, so the fog would have nothing to dim and would
            // look broken. Only on the transition, so a resize does not fight
            // the user's own zooming.
            if lockedTilesAcross == nil, oldValue != nil { zoom = Self.defaultZoom }
            applyLockedZoom()
        }
    }

    private func applyLockedZoom() {
        guard let tiles = lockedTilesAcross, tiles > 0, size.width > 0 else { return }
        zoom = size.width / (CGFloat(tiles) * TileArt.size)
        follow = true
        centreOnExplorer(animated: false)
        refreshStatus()
    }

    /// The view is `.resizeFill`, so the scene follows the viewport — and a
    /// locked aperture has to be recomputed when it does, or resizing the window
    /// silently changes how many tiles the classic mode shows.
    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        applyLockedZoom()
    }
    private var overviewMap: SKSpriteNode?
    /// Held so their filtering can follow the zoom.
    private var detailTextures: [SKTexture] = []
    private var follow = true

    init(map: WorldMap, style: TileStyle, originals: OriginalTiles?, size: CGSize) {
        self.map = map
        self.style = style
        self.originals = originals
        self.position2D = map.suggestedStart() ?? (map.width / 2, map.height / 2)
        self.fog = FogOfWar(width: map.width, height: map.height)
        self.fog.look(from: self.position2D)
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = NSColor(srgbRed: 0.03, green: 0.07, blue: 0.18, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMove(to view: SKView) {
        buildOverviewMap()
        buildTileMap()
        buildFog()

        explorer.fillColor = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.2, alpha: 1)
        explorer.strokeColor = .black
        explorer.lineWidth = 2
        explorer.zPosition = 10
        addChild(explorer)

        camera = cam
        addChild(cam)

        applyZoom()
        applyLockedZoom()
        centreOnExplorer(animated: false)
        refreshStatus()
    }

    /// Terrain is drawn from the tile's map position in the original, not from
    /// one bitmap per type, so a group is built per (terrain, variant) and the
    /// fill below picks between them. Mountains only join into ranges, and woods
    /// only read as individual trees, because of this. See `TerrainTiles`.
    /// Keyed by the *variant*, not the position. Keying by position created
    /// sixteen identical groups for every terrain that does not vary — 272 tile
    /// groups in a set, almost all duplicates — where keying by variant needs
    /// about forty.
    private func variantKey(_ terrain: Terrain, x: Int, y: Int) -> String {
        guard style == .original, let o = originals else {
            return String(describing: terrain)
        }
        return "\(terrain)#\(o.variant(for: terrain, x: x, y: y))"
    }

    /// Detail art is only drawn once a tile is at least its texture's own
    /// size on screen.
    ///
    /// Below that the texture is minified, and with nearest-neighbour sampling
    /// minification *drops* pixels rather than averaging them. A river is two
    /// pixels wide inside its tile, so it survives in some tiles and vanishes
    /// in others — which reads as a river breaking into fragments. Woods and
    /// peaks thin out the same way. The flat overview has no fine detail to
    /// lose, so it stays legible all the way out.
    ///
    /// An earlier 0.6 was still deep into minification and shipped exactly that
    /// artifact.
    /// The real art is kept until a tile is only a few pixels across.
    ///
    /// It survives being minified perfectly well *if* minification averages
    /// rather than drops — see `applyZoom`, which switches filtering with the
    /// zoom. An earlier version swapped to flat colour below 1.0, which was
    /// compensating for a filtering choice rather than a real limit, and threw
    /// away the terrain art across the whole range people browse at.
    static let detailZoomThreshold: CGFloat = 0.3

    /// The overview is **one image**, a single pixel per map tile, stretched
    /// over the world and filtered.
    ///
    /// It was a tile map of flat-coloured quads, which cannot be interpolated:
    /// `filteringMode` samples *within* a texture, and there each tile was its
    /// own texture, so every tile stayed a hard-edged square however far you
    /// zoomed out. Drawing the whole world as one small texture instead means
    /// linear filtering has something to work with, and the map softens into
    /// coastlines and river courses rather than a mosaic. It is also far
    /// cheaper: one node and a 256x400 texture instead of a hundred thousand
    /// tile quads.
    private func buildOverviewMap() {
        let w = map.width, h = map.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }

        for y in 0..<h {
            for x in 0..<w {
                // The context is bottom-up; the map is stored top-down.
                let color = TileArt.flatColor(for: map[x, h - 1 - y])
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        guard let cg = ctx.makeImage() else { return }

        let texture = SKTexture(cgImage: cg)
        texture.filteringMode = .linear
        let node = SKSpriteNode(texture: texture)
        node.anchorPoint = .zero
        node.position = .zero
        node.size = CGSize(width: CGFloat(w) * TileArt.size,
                           height: CGFloat(h) * TileArt.size)
        node.zPosition = 0.5
        overviewMap = node
        addChild(node)
    }

    private func buildTileMap() {
        var groups: [String: SKTileGroup] = [:]
        for terrain in Terrain.allCases {
            if style == .original, let o = originals {
                for v in 0..<o.variantCount(for: terrain) {
                    let key = "\(terrain)#\(v)"
                    guard groups[key] == nil,
                          let texture = o.texture(for: terrain, variant: v)
                    else { continue }
                    let group = SKTileGroup(tileDefinition: SKTileDefinition(texture: texture))
                    group.name = key
                    groups[key] = group
                    detailTextures.append(texture)
                }
            }
            let key = String(describing: terrain)
            if groups[key] == nil {
                let texture = TileArt.texture(for: terrain)
                let group = SKTileGroup(tileDefinition: SKTileDefinition(texture: texture))
                group.name = key
                groups[key] = group
            }
        }
        let set = SKTileSet(tileGroups: Array(groups.values))
        tileMap = SKTileMapNode(
            tileSet: set,
            columns: map.width,
            rows: map.height,
            tileSize: CGSize(width: TileArt.size, height: TileArt.size))
        tileMap.anchorPoint = .zero
        tileMap.position = .zero

        for y in 0..<map.height {
            // SpriteKit rows run bottom-up; the map is stored top-down.
            let row = map.height - 1 - y
            for x in 0..<map.width {
                let terrain = map[x, row]
                let key = variantKey(terrain, x: x, y: row)
                tileMap.setTileGroup(groups[key] ?? groups[String(describing: terrain)],
                                     forColumn: x, row: y)
            }
        }
        addChild(tileMap)
    }

    // MARK: - Camera

    private func worldPoint(_ x: Int, _ y: Int) -> CGPoint {
        CGPoint(x: (CGFloat(x) + 0.5) * TileArt.size,
                y: (CGFloat(map.height - 1 - y) + 0.5) * TileArt.size)
    }

    private func applyZoom() {
        cam.setScale(1.0 / zoom)
        let overview = zoom < Self.detailZoomThreshold
        overviewMap?.isHidden = !overview
        tileMap?.isHidden = overview
        // Deliberately *not* switching to linear when shrinking. SpriteKit has
        // one filtering mode per texture, and linear with mipmaps drops to a
        // lower mip level and then magnifies it, which smears pixel art into
        // mush even at 0.89x. Nearest holds up now that a tile texture is the
        // same size as its cell; the earlier breakage was a 64-pixel texture in
        // a 32-point cell, not the filter.
        // Keep the explorer marker a readable size on screen at any zoom.
        explorer.setScale(max(0.35, 1.0 / zoom))
    }

    // MARK: - Fog of war

    /// How dark a cell is drawn, as an alpha over black.
    ///
    /// `remembered` is a judgement rather than a measurement: enough to read as
    /// memory beside lit ground, not so much that a coastline stops being
    /// legible. `unseen` is total, so the world genuinely fills in behind you.
    private static let rememberedAlpha: UInt8 = 150
    private static let unseenAlpha: UInt8 = 255

    /// One pixel per map cell, stretched over the world and linearly filtered.
    ///
    /// The filtering is the whole trick, and it is the one lesson worth taking
    /// from the roguelike's fog: dimming has to feather *across* cell edges
    /// rather than step at them, or the explored frontier reads as a staircase
    /// of hard squares. A per-cell overlay of flat quads cannot be interpolated —
    /// each quad is its own texture and `filteringMode` samples within a texture,
    /// not between them. One small texture over the whole map gives linear
    /// sampling something to work with, and the boundary softens over a cell.
    /// It is also cheap: a single node, and the same technique the overview map
    /// already uses.
    private func buildFog() {
        fogPixels = [UInt8](repeating: 0, count: map.width * map.height * 4)
        let node = SKSpriteNode()
        node.anchorPoint = .zero
        node.position = .zero
        node.size = CGSize(width: CGFloat(map.width) * TileArt.size,
                           height: CGFloat(map.height) * TileArt.size)
        // Above both the tile map and the overview, below the explorer — which
        // must stay visible, since it is the one thing you always know.
        node.zPosition = 5
        node.isHidden = !fogEnabled
        fogNode = node
        addChild(node)
        updateFog()
    }

    private func updateFog() {
        // Skipped while hidden — but `fog` itself has already been updated by the
        // caller, so nothing is lost by not drawing it, and switching the fog
        // back on rebuilds from state that stayed current.
        guard let fogNode, fogEnabled else { return }
        let w = map.width, h = map.height
        // No vertical flip here, unlike `buildOverviewMap`, and the difference is
        // the thing to remember: that one *draws through* the context, whose
        // coordinates are bottom-up, so it has to flip. This writes bytes into
        // the backing buffer, and a bitmap buffer's first row is the image's
        // *top* row. Flipping as well mirrored the fog — the lit circle appeared
        // two hundred rows from the expedition, and everything you could see was
        // black.
        for y in 0..<h {
            for x in 0..<w {
                let alpha: UInt8 = switch fog.visibility(x: x, y: y) {
                case .unseen: Self.unseenAlpha
                case .remembered: Self.rememberedAlpha
                case .visible: 0
                }
                // Black, premultiplied, so only the alpha carries anything.
                let i = (y * w + x) * 4
                fogPixels[i] = 0
                fogPixels[i + 1] = 0
                fogPixels[i + 2] = 0
                fogPixels[i + 3] = alpha
            }
        }
        // The image is made inside the exclusive-access closure and everything
        // else outside it. Touching `fogPixels` again while that access is held
        // is an exclusivity violation and traps at runtime — which it did.
        let image: CGImage? = fogPixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            return ctx.makeImage()
        }
        guard let image else { return }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .linear
        fogNode.texture = texture
        fogNode.size = CGSize(width: CGFloat(w) * TileArt.size,
                              height: CGFloat(h) * TileArt.size)
    }

    private func centreOnExplorer(animated: Bool) {
        let p = worldPoint(position2D.x, position2D.y)
        explorer.position = p
        guard follow else { return }
        if animated {
            cam.run(.move(to: p, duration: 0.08))
        } else {
            cam.position = p
        }
    }

    /// Two short lines, because they have to fit under the classic aperture —
    /// which is a narrower screen than the wide one, not a wider one. The single
    /// forty-character line this replaced ran off both edges of it.
    ///
    /// Zoom is gone from here deliberately: it means nothing while the aperture
    /// is pinned, and the two lines the original has there are worth more spent
    /// on the world than on the renderer.
    private func refreshStatus() {
        let t = map[position2D.x, position2D.y]
        let tiles = (style == .original && originals != nil) ? "original" : "custom"
        let seen = String(format: "%.1f", fog.exploredFraction * 100)
        onStatusChange?([
            "X \(position2D.x)  Y \(position2D.y)    TERRAIN: \(t.displayName)",
            "SEEN: \(seen)%    TILES: \(tiles)" + (follow ? "" : "    [FREE LOOK]"),
        ])
    }

    // MARK: - Input

    /// The three schemes decided for the port: arrows, numpad, and the cluster
    /// around J. The original was 8-way plus one button, so this is the whole
    /// input surface.
    private func direction(for event: NSEvent) -> (Int, Int)? {
        if let special = event.specialKey {
            switch special {
            case .upArrow: return (0, -1)
            case .downArrow: return (0, 1)
            case .leftArrow: return (-1, 0)
            case .rightArrow: return (1, 0)
            default: return nil
            }
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "7", "y": return (-1, -1)
        case "8", "u": return (0, -1)
        case "9", "i": return (1, -1)
        case "4", "h": return (-1, 0)
        case "6", "k": return (1, 0)
        case "1", "n": return (-1, 1)
        case "2", "m": return (0, 1)
        case "3", ",": return (1, 1)
        default: return nil
        }
    }

    override func keyDown(with event: NSEvent) {
        // Zooming and free look are the wide aperture's affordances. Under the
        // classic one the window is the point, so they are simply not offered.
        if lockedTilesAcross == nil {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "=", "+": zoom = min(zoom * 1.25, 12); refreshStatus(); return
            case "-", "_": zoom = max(zoom / 1.25, 0.12); refreshStatus(); return
            case "0": zoom = 0.16; follow = false; cam.position = CGPoint(
                x: CGFloat(map.width) * TileArt.size / 2,
                y: CGFloat(map.height) * TileArt.size / 2); refreshStatus(); return
            case "f": follow.toggle(); centreOnExplorer(animated: true); refreshStatus(); return
            default: break
            }
        }
        guard let (dx, dy) = direction(for: event) else { return }
        let nx = position2D.x + dx, ny = position2D.y + dy
        guard map.contains(x: nx, y: ny) else { return }
        position2D = (nx, ny)
        fog.look(from: position2D)
        updateFog()
        follow = true
        centreOnExplorer(animated: true)
        refreshStatus()
    }

    override func scrollWheel(with event: NSEvent) {
        guard lockedTilesAcross == nil else { return }
        follow = false
        cam.position.x -= event.scrollingDeltaX / zoom
        cam.position.y += event.scrollingDeltaY / zoom
        refreshStatus()
    }

    override func magnify(with event: NSEvent) {
        guard lockedTilesAcross == nil else { return }
        zoom = min(max(zoom * (1 + event.magnification), 0.12), 12)
        refreshStatus()
    }

    override func mouseDragged(with event: NSEvent) {
        guard lockedTilesAcross == nil else { return }
        follow = false
        cam.position.x -= event.deltaX / zoom
        cam.position.y += event.deltaY / zoom
    }
}
