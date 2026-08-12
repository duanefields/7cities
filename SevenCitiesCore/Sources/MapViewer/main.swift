import AppKit
import ImageIO
import SevenCitiesCore
import SpriteKit
import UniformTypeIdentifiers

// Plain AppKit entry point rather than a SwiftUI App, so the viewer runs
// straight from `swift run` without needing an app bundle.

/// Which world to show. Both come from disks you own, via
/// `tools/extract_map.py`; neither ships with the engine.
enum MapChoice {
    case historical
    case generated(seed: UInt16)

    var title: String {
        switch self {
        case .historical: "Classic (North & South America)"
        case .generated(let s): "Generated World #\(s)"
        }
    }
}

@MainActor
final class ViewerController: NSObject, NSApplicationDelegate {

    private let assetDirectory: URL
    private var window: NSWindow!
    private var skView: SKView!
    private var hud: NSTextField!
    private var mapChoice: MapChoice = .historical      // default: the classic map
    private var generated: WorldMap?
    private var tileStyle: TileStyle = .original        // default: in-game tiles
    private var originals: OriginalTiles?

    init(assetDirectory: URL) {
        self.assetDirectory = assetDirectory
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let frame = NSRect(x: 0, y: 0, width: 1100, height: 750)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.center()

        let container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]

        skView = SKView(frame: frame)
        skView.autoresizingMask = [.width, .height]
        skView.ignoresSiblingOrder = true
        container.addSubview(skView)

        // The HUD is an AppKit view pinned to the top-left, so it keeps a
        // constant size and position no matter how far the map is zoomed.
        hud = NSTextField(labelWithString: "")
        hud.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        hud.textColor = .white
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        hud.drawsBackground = true
        hud.isBezeled = false
        hud.isEditable = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hud)
        NSLayoutConstraint.activate([
            hud.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
        ])

        window.contentView = container
        window.makeKeyAndOrderFront(nil)

        buildMenus()
        reload()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menus

    private func buildMenus() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let worldItem = NSMenuItem()
        let worldMenu = NSMenu(title: "World")
        let classic = NSMenuItem(title: "Classic Map (North & South America)",
                                 action: #selector(pickClassic), keyEquivalent: "1")
        classic.target = self
        worldMenu.addItem(classic)
        // Not a sticky choice: every invocation makes a fresh world.
        let gen = NSMenuItem(title: "Generate New World",
                             action: #selector(generateWorld), keyEquivalent: "g")
        gen.target = self
        worldMenu.addItem(gen)
        worldItem.submenu = worldMenu
        main.addItem(worldItem)

        let tilesItem = NSMenuItem()
        let tilesMenu = NSMenu(title: "Tiles")
        for style in TileStyle.allCases {
            let item = NSMenuItem(title: style.rawValue,
                                  action: #selector(pickStyle(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            tilesMenu.addItem(item)
        }
        tilesItem.submenu = tilesMenu
        main.addItem(tilesItem)

        NSApp.mainMenu = main
        refreshChecks()
    }

    private func refreshChecks() {
        for menu in NSApp.mainMenu?.items ?? [] {
            for item in menu.submenu?.items ?? [] {
                guard let tag = item.representedObject as? String else { continue }
                item.state = (tag == tileStyle.rawValue) ? .on : .off
            }
        }
    }

    @objc private func pickClassic() {
        mapChoice = .historical
        reload()
    }

    @objc private func generateWorld() {
        let seed = UInt16.random(in: 1...UInt16.max)
        var generator = WorldGenerator(seed: seed)
        generated = generator.generate()
        mapChoice = .generated(seed: seed)
        reload()
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = TileStyle.allCases.first(where: { $0.rawValue == raw })
        else { return }
        tileStyle = style
        reload()
    }

    // MARK: - Loading

    private func reload() {
        let url = assetDirectory.appendingPathComponent("historical.map")
        let loaded: WorldMap?
        switch mapChoice {
        case .historical: loaded = try? WorldMap(contentsOf: url)
        case .generated: loaded = generated
        }
        guard let map = loaded else {
            window.title = "Seven Cities — historical.map not found"
            let scene = SKScene(size: skView.bounds.size)
            scene.backgroundColor = .black
            let label = SKLabelNode(fontNamed: "Menlo")
            label.text = "historical.map not found — run ./extract.sh, or press G to generate a world"
            label.fontSize = 14
            label.position = CGPoint(x: skView.bounds.midX, y: skView.bounds.midY)
            scene.addChild(label)
            skView.presentScene(scene)
            return
        }

        if originals == nil { originals = OriginalTiles.load(nextTo: url) }
        let haveOriginals = originals != nil
        let effective: TileStyle = (tileStyle == .original && !haveOriginals)
            ? .custom : tileStyle

        let scene = WorldScene(map: map, style: effective,
                               originals: originals, size: skView.bounds.size)
        scene.onStatusChange = { [weak self] text in self?.hud.stringValue = " \(text) " }
        skView.presentScene(scene)
        window.makeFirstResponder(skView)

        var title = "Seven Cities — \(mapChoice.title) — \(effective.rawValue) tiles"
        if tileStyle == .original && !haveOriginals {
            title += "  (original_tiles.json missing; run tools/extract_tiles.py)"
        } else if effective == .original, let o = originals {
            title += "  (\(o.capturedCount)/\(o.tiles.count) captured, rest reconstructed)"
        }
        window.title = title
        refreshChecks()
    }
}

nonisolated(unsafe) var delegateBox: AnyObject?

let args = CommandLine.arguments
let assets = URL(fileURLWithPath: args.count > 1 ? args[1] : "assets")

// Headless check: MapViewer <assets> --dump <out.png> [historical|generated] [original|custom]
if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
    let file = args.contains("generated") ? "generated.map" : "historical.map"
    let style: TileStyle = args.contains("custom") ? .custom : .original
    var seed: UInt16?
    if let j = args.firstIndex(of: "--gen"), j + 1 < args.count {
        seed = UInt16(args[j + 1])
    }
    exit(DumpMode.run(assetDirectory: assets, mapFile: file, style: style,
                      out: URL(fileURLWithPath: args[i + 1]), generateSeed: seed))
}
print("assets: \(assets.path)")

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = ViewerController(assetDirectory: assets)
    // The delegate is not otherwise retained once this scope exits.
    delegateBox = controller
    app.delegate = controller
    app.setActivationPolicy(.regular)
    app.run()
}
