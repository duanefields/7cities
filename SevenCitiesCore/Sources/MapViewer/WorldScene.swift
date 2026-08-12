import AppKit
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
    var onStatusChange: (@MainActor (String) -> Void)?

    private var position2D: (x: Int, y: Int)
    private var zoom: CGFloat = 3.0 { didSet { applyZoom() } }
    private var follow = true

    init(map: WorldMap, style: TileStyle, originals: OriginalTiles?, size: CGSize) {
        self.map = map
        self.style = style
        self.originals = originals
        self.position2D = map.suggestedStart() ?? (map.width / 2, map.height / 2)
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = NSColor(srgbRed: 0.03, green: 0.07, blue: 0.18, alpha: 1)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMove(to view: SKView) {
        buildTileMap()

        explorer.fillColor = NSColor(srgbRed: 1.0, green: 0.85, blue: 0.2, alpha: 1)
        explorer.strokeColor = .black
        explorer.lineWidth = 2
        explorer.zPosition = 10
        addChild(explorer)

        camera = cam
        addChild(cam)

        applyZoom()
        centreOnExplorer(animated: false)
        refreshStatus()
    }

    private func buildTileMap() {
        var groups: [Terrain: SKTileGroup] = [:]
        for terrain in Terrain.allCases {
            let texture: SKTexture
            if style == .original, let t = originals?.texture(for: terrain) {
                texture = t
            } else {
                texture = TileArt.texture(for: terrain)
            }
            let def = SKTileDefinition(texture: texture)
            let group = SKTileGroup(tileDefinition: def)
            group.name = String(describing: terrain)
            groups[terrain] = group
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
                tileMap.setTileGroup(groups[map[x, row]], forColumn: x, row: y)
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
        // Keep the explorer marker a readable size on screen at any zoom.
        explorer.setScale(max(0.35, 1.0 / zoom))
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

    private func refreshStatus() {
        let t = map[position2D.x, position2D.y]
        let tiles = (style == .original && originals != nil) ? "original" : "custom"
        onStatusChange?(
            "(\(position2D.x), \(position2D.y))    TERRAIN: \(t.displayName)"
            + "    ZOOM: \(String(format: "%.2f", zoom))x    TILES: \(tiles)"
            + (follow ? "" : "    [free look]"))
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
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "=", "+": zoom = min(zoom * 1.25, 12); refreshStatus(); return
        case "-", "_": zoom = max(zoom / 1.25, 0.12); refreshStatus(); return
        case "0": zoom = 0.16; follow = false; cam.position = CGPoint(
            x: CGFloat(map.width) * TileArt.size / 2,
            y: CGFloat(map.height) * TileArt.size / 2); refreshStatus(); return
        case "f": follow.toggle(); centreOnExplorer(animated: true); refreshStatus(); return
        default: break
        }
        guard let (dx, dy) = direction(for: event) else { return }
        let nx = position2D.x + dx, ny = position2D.y + dy
        guard map.contains(x: nx, y: ny) else { return }
        position2D = (nx, ny)
        follow = true
        centreOnExplorer(animated: true)
        refreshStatus()
    }

    override func scrollWheel(with event: NSEvent) {
        follow = false
        cam.position.x -= event.scrollingDeltaX / zoom
        cam.position.y += event.scrollingDeltaY / zoom
        refreshStatus()
    }

    override func magnify(with event: NSEvent) {
        zoom = min(max(zoom * (1 + event.magnification), 0.12), 12)
        refreshStatus()
    }

    override func mouseDragged(with event: NSEvent) {
        follow = false
        cam.position.x -= event.deltaX / zoom
        cam.position.y += event.deltaY / zoom
    }
}
