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
    /// The expedition. A real ship when the original art is available, and a
    /// plain marker when it is not.
    private let explorer = SKSpriteNode()
    /// Whether `explorer` is carrying the original's ship tile, which is one map
    /// tile square and must not be rescaled to stay a constant size on screen
    /// the way a bare marker is.
    private var explorerIsShip = false

    /// Called with the status text whenever it changes. The HUD lives in the
    /// window as an AppKit view rather than as a node, because anything
    /// parented to the camera inherits the camera transform and therefore
    /// shrinks, grows and drifts off-screen as you zoom.
    var onStatusChange: (@MainActor ([String]) -> Void)?

    /// Transient text for the line the original announces discoveries on. Empty
    /// means "nothing to say", and the owner puts its own default back.
    var onMessage: (@MainActor (String) -> Void)?

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
            if fogEnabled { updateFog(full: true) }
            refreshStatus()
        }
    }
    /// Reused between updates: one RGBA byte per map cell. Rebuilt on every step,
    /// so it is not worth reallocating 400 KB each time.
    private var fogPixels: [UInt8] = []
    /// Where the eye was when the fog was last painted, so the next paint can
    /// touch only what that move could have changed.
    private var paintedEye: (x: Int, y: Int)?
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
        // At sea, because the expedition arrives by ship. `suggestedStart` finds
        // land and is what the free-roaming viewer wanted.
        self.position2D = map.shipStart() ?? (map.width / 2, map.height / 2)
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

        // `$5529` entry `$3` is the ship, and it is one of the static patterns
        // `extract.sh` already pulls off the program disk — so the expedition can
        // be the game's own ship rather than a stand-in, with no new art.
        if style == .original, let texture = originals?.texture(for: .ship, variant: 0) {
            explorer.texture = texture
            explorer.size = CGSize(width: TileArt.size, height: TileArt.size)
            explorerIsShip = true
        } else {
            explorer.color = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.2, alpha: 1)
            explorer.size = CGSize(width: TileArt.size * 0.64, height: TileArt.size * 0.64)
        }
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
        // A bare marker is kept a readable size on screen whatever the zoom; the
        // ship is a map tile and stays the size of one, or it would swim free of
        // the water it is sitting on.
        explorer.setScale(explorerIsShip ? 1.0 : max(0.35, 1.0 / zoom))
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

    /// Repaint the fog texture.
    ///
    /// A step changes the alpha of very few cells: only those that fell in or out
    /// of the sight radius, which is a block around where the eye was and one
    /// around where it now is. Everything else is exactly as it was already
    /// painted. Repainting all 102,400 every step cost more than the move itself
    /// and was part of what made moving feel jerky, so by default only those two
    /// windows are touched.
    ///
    /// `full` forces the whole map, which is needed the first time and after the
    /// fog has been hidden — while hidden the state keeps advancing, so the two
    /// windows would no longer describe everything that changed.
    private func updateFog(full: Bool = false) {
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
        func paint(_ xs: ClosedRange<Int>, _ ys: ClosedRange<Int>) {
            for y in ys {
                for x in xs {
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
        }
        // The sight radius plus one, since the cell just outside the old block is
        // the one that has to darken.
        func window(around eye: (x: Int, y: Int)) -> (ClosedRange<Int>, ClosedRange<Int>) {
            let r = FogOfWar.sightRadius + 1
            return (max(0, eye.x - r)...min(w - 1, eye.x + r),
                    max(0, eye.y - r)...min(h - 1, eye.y + r))
        }

        if full || paintedEye == nil {
            paint(0...(w - 1), 0...(h - 1))
        } else {
            if let was = paintedEye { let (xs, ys) = window(around: was); paint(xs, ys) }
            if let now = fog.eye { let (xs, ys) = window(around: now); paint(xs, ys) }
        }
        paintedEye = fog.eye
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

    /// The camera and the ship move together, in one step, with no tween.
    ///
    /// They used to disagree: the ship's position was set outright while the
    /// camera was given an 0.08s `move(to:)`. For that eighth of a second the
    /// ship slid across the world instead of the world sliding under the ship,
    /// which is the ghosting you see while moving — and it is worst exactly
    /// where the tiles are biggest, because the same tween covers more pixels.
    /// Snapping both is also what the original does: it scrolls the map by whole
    /// tiles, never between them.
    ///
    /// `animated` is kept in the signature because the call sites read better
    /// for it, but there is deliberately nothing left to animate.
    private func centreOnExplorer(animated: Bool) {
        let p = worldPoint(position2D.x, position2D.y)
        explorer.position = p
        cam.removeAllActions()
        guard follow else { return }
        cam.position = p
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

    /// Every way to steer, all live at once. The original was eight directions
    /// and one button, so this is the whole input surface.
    ///
    /// - **Arrows** for the four cardinals.
    /// - **Numpad**, which is the eight directions laid out as they point.
    /// - **`WASD` with its diagonals** — `Q W E / A S D / Z X C`. `S` is south
    ///   here, not a stand-still: there is no turn economy for a rest key to
    ///   mean anything in, and `WASD` is what the muscle memory expects.
    /// - **vi keys**, `Y U I / H J K L / B N M`, for people who prefer them.
    ///
    /// The vi set is an alternative rather than the default, which is how Duane's
    /// roguelike offers them too. It costs nothing to have both: the two letter
    /// clusters do not share a single key, so neither has to be chosen.
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
        case "7", "q", "y": return (-1, -1)
        case "8", "w", "k": return (0, -1)
        case "9", "e", "u": return (1, -1)
        case "4", "a", "h": return (-1, 0)
        case "6", "d", "l": return (1, 0)
        case "1", "z", "b": return (-1, 1)
        case "2", "s", "j": return (0, 1)
        case "3", "c", "n": return (1, 1)
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
        // A ship keeps to the water. Landing, and walking once landed, is the
        // next chunk; until then the coast is a wall rather than a beach.
        guard map[nx, ny].isWater else {
            onMessage?("THE SHIP CANNOT SAIL ON LAND")
            return
        }
        onMessage?("")
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
