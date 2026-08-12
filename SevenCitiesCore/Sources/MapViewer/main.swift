import AppKit
import ImageIO
import SevenCitiesCore
import SpriteKit
import UniformTypeIdentifiers

// Plain AppKit entry point rather than a SwiftUI App, so the viewer runs
// straight from `swift run` without needing an app bundle.

/// Which world to show. Both come from disks you own, via
/// `tools/extract_map.py`; neither ships with the engine.
enum MapChoice: String, CaseIterable {
    case historical = "Classic (North & South America)"
    case generated = "Generated World"

    var filename: String {
        switch self {
        case .historical: "historical.map"
        case .generated: "generated.map"
        }
    }
}

final class ViewerController: NSObject, NSApplicationDelegate {

    private let assetDirectory: URL
    private var window: NSWindow!
    private var skView: SKView!
    private var mapChoice: MapChoice = .historical      // default: the classic map
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

        skView = SKView(frame: frame)
        skView.ignoresSiblingOrder = true
        window.contentView = skView
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
        for (i, choice) in MapChoice.allCases.enumerated() {
            let item = NSMenuItem(title: choice.rawValue,
                                  action: #selector(pickMap(_:)),
                                  keyEquivalent: String(i + 1))
            item.target = self
            item.representedObject = choice.rawValue
            worldMenu.addItem(item)
        }
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
        NSApp.mainMenu?.item(withTitle: "")?.submenu?.items.forEach { _ in }
        for menu in NSApp.mainMenu?.items ?? [] {
            for item in menu.submenu?.items ?? [] {
                guard let tag = item.representedObject as? String else { continue }
                item.state = (tag == mapChoice.rawValue || tag == tileStyle.rawValue)
                    ? .on : .off
            }
        }
    }

    @objc private func pickMap(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = MapChoice.allCases.first(where: { $0.rawValue == raw })
        else { return }
        mapChoice = choice
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
        let url = assetDirectory.appendingPathComponent(mapChoice.filename)
        guard let map = try? WorldMap(contentsOf: url) else {
            window.title = "Seven Cities — missing \(mapChoice.filename)"
            let scene = SKScene(size: skView.bounds.size)
            scene.backgroundColor = .black
            let label = SKLabelNode(fontNamed: "Menlo")
            label.text = "Missing \(mapChoice.filename) — run tools/extract_map.py"
            label.fontSize = 15
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
        skView.presentScene(scene)
        window.makeFirstResponder(skView)

        var title = "Seven Cities — \(mapChoice.rawValue) — \(effective.rawValue) tiles"
        if tileStyle == .original && !haveOriginals {
            title += "  (original_tiles.json missing; run tools/extract_tiles.py)"
        } else if effective == .original, let o = originals {
            title += "  (\(o.capturedCount)/\(o.tiles.count) captured, rest reconstructed)"
        }
        window.title = title
        refreshChecks()
    }
}

let args = CommandLine.arguments
let assets = URL(fileURLWithPath: args.count > 1 ? args[1] : "local")

// Headless check: MapViewer <assets> --dump <out.png> [historical|generated] [original|custom]
if let i = args.firstIndex(of: "--dump"), i + 1 < args.count {
    let file = args.contains("generated") ? "generated.map" : "historical.map"
    let style: TileStyle = args.contains("custom") ? .custom : .original
    exit(DumpMode.run(assetDirectory: assets, mapFile: file, style: style,
                      out: URL(fileURLWithPath: args[i + 1])))
}
print("assets: \(assets.path)")

let app = NSApplication.shared
let controller = ViewerController(assetDirectory: assets)
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
