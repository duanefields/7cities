import AppKit
import ImageIO
import SevenCitiesCore
import SpriteKit
import UniformTypeIdentifiers

// The viewer lives in a library so two front ends can share it: the `MapViewer`
// command, which runs it straight from `swift run` with no app bundle, and the
// Xcode app target, which wraps it in a real bundle. Neither duplicates any of
// this.

/// Which world to show. The classic map comes from a disk you own; neither it
/// nor the original art ships with the engine.
public enum MapChoice {
    case historical
    /// `config` is which of the World Maker's three worlds `$2146` chose.
    case generated(seed: UInt16, config: Int)

    public var title: String {
        switch self {
        case .historical: "Classic (North & South America)"
        case .generated(let s, let c):
            "Generated World — seed $\(String(format: "%04X", s)), world \(c + 1)"
        }
    }
}

@MainActor
public final class ViewerController: NSObject, NSApplicationDelegate {

    private var assetDirectory: URL
    private var window: NSWindow!
    private var skView: SKView!
    private var hud: NSTextField!
    private var mapChoice: MapChoice = .historical      // default: the classic map
    private var generated: WorldMap?
    private var tileStyle: TileStyle = .original        // default: in-game tiles
    private var originals: OriginalTiles?

    /// - Parameter assetDirectory: where `historical.map` and
    ///   `original_tiles.json` live. Defaults to the app's Application Support
    ///   directory so a bundled app needs no arguments.
    public init(assetDirectory: URL = AssetExtractor.defaultAssetDirectory) {
        self.assetDirectory = assetDirectory
    }

    public func applicationDidFinishLaunching(_ note: Notification) {
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

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let importItem = NSMenuItem(title: "Import Disk Images…",
                                    action: #selector(importDisks), keyEquivalent: "o")
        importItem.target = self
        fileMenu.addItem(importItem)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

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

        let paletteItem = NSMenuItem()
        let paletteMenu = NSMenu(title: "Palette")
        for p in OriginalTiles.C64Palette.allCases {
            let item = NSMenuItem(title: p.rawValue, action: #selector(pickPalette(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = p.rawValue
            paletteMenu.addItem(item)
        }
        paletteItem.submenu = paletteMenu
        main.addItem(paletteItem)

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
                item.state = (tag == tileStyle.rawValue
                              || tag == OriginalTiles.palette.rawValue) ? .on : .off
            }
        }
    }

    /// Extracts from disk images the user picks, so the app is self-contained
    /// and nobody has to run a script or pass a path to get the classic map and
    /// the original art.
    @objc private func importDisks() {
        let panel = NSOpenPanel()
        panel.title = "Choose your Seven Cities of Gold disk images"
        panel.message = "Pick one or both sides. No game data ships with this app —"
            + " these must be images of disks you own."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        let destination = AssetExtractor.defaultAssetDirectory
        do {
            let report = try AssetExtractor.extract(images: panel.urls, to: destination)
            assetDirectory = destination
            originals = nil                 // force a reload from the new assets
            if report.historicalMap != nil { mapChoice = .historical }
            reload()
            let alert = NSAlert()
            alert.messageText = report.wroteAnything ? "Extracted" : "Nothing extracted"
            alert.informativeText = ([report.summary] + report.notes)
                .joined(separator: "\n")
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Could not read those disk images"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    @objc private func pickClassic() {
        mapChoice = .historical
        reload()
    }

    @objc private func generateWorld() {
        // Two inputs, not one. `seed` is the generator's state where the
        // land-mass phase picks it up, and the configuration is what `$2146`
        // chose from a draw *before* that — which the port does not model, so
        // it is drawn here the same way: a byte over ninety.
        let seed = UInt16.random(in: 1...UInt16.max)
        let config = Int(UInt8.random(in: 0...255)) / 90
        do {
            let world = try WorldMaker.world(config: config, seed: seed)
            generated = WorldMap(world)
            mapChoice = .generated(seed: seed, config: config)
            reload()
        } catch {
            NSSound.beep()
            FileHandle.standardError.write(
                Data("could not generate a world: \(error)\n".utf8))
        }
    }

    /// The C64 emits composite video, so every palette is a model of it and
    /// none is definitive — VICE's own default is one, Pepto and Colodore are
    /// others. Rather than keep guessing which looks right, offer them.
    @objc private func pickPalette(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = OriginalTiles.C64Palette.allCases.first(where: { $0.rawValue == raw })
        else { return }
        OriginalTiles.palette = p
        TileArt.clearCaches()
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
        // Someone who has not supplied disk images should still get a world to
        // walk around rather than an error screen, so fall back to generating
        // one. Only an explicit request for the classic map can fail.
        if loaded == nil, case .historical = mapChoice, generated == nil {
            generateWorld()
            return
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
            title += "  (no original art — use File ▸ Import Disk Images…)"
        } else if effective == .original, let o = originals {
            let animated = o.tiles.count - o.patternCount
            title += "  (\(o.patternCount) original patterns, \(animated) animated)"
        }
        window.title = title
        refreshChecks()
    }
}
