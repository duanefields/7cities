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
    /// `seed` is `nil` for a world generated the way the game does it, where a
    /// seed identifies nothing — see `WorldMaker.randomWorld()`.
    case generated(seed: UInt16?, config: Int)

    public var title: String {
        switch self {
        case .historical: "Classic (North & South America)"
        case .generated(let s, let c):
            s.map { "Generated World — seed $\(String(format: "%04X", $0)), world \(c + 1)" }
                ?? "Generated World — world \(c + 1)"
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
    private var container: NSView!
    private var shell: GameShellView!
    private var font: GameFont?
    /// Non-nil while the New Game screen is up, which is also how the rest of
    /// this knows a session has not started yet.
    private var newGameView: NewGameView?
    private var scene: WorldScene?
    /// How much world the window shows, and with it whether the fog is drawn at
    /// all. Defaults to the wide window; `.classic` is the faithful one.
    private var aperture: Aperture = .classic

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

        container = NSView(frame: frame)
        container.autoresizingMask = [.width, .height]

        font = GameFont.load(in: assetDirectory)
        shell = GameShellView(font: font)
        shell.autoresizingMask = [.width, .height]
        container.addSubview(shell)

        // The map sits in the hole the shell leaves, as a child of the shell
        // rather than a sibling. The shell is flipped and the container is not,
        // so a viewport rect handed across that boundary would need its y
        // mirrored — and the first version of this got that wrong. Inside the
        // shell there is only one coordinate space and no conversion to forget.
        skView = SKView(frame: .zero)
        skView.ignoresSiblingOrder = true
        shell.addSubview(skView)

        // Wire the callback before giving the shell a size, or the first layout
        // — the only one that runs if the window is never resized — reports to
        // nobody and the map view keeps whatever frame it was born with.
        shell.onViewportChange = { [weak self] rect in self?.skView.frame = rect }
        shell.frame = frame
        skView.frame = shell.viewportRect

        // The HUD is an AppKit view pinned to the top-left, so it keeps a
        // constant size and position no matter how far the map is zoomed.
        // Kept, but never shown: the shell draws status in the game's own font
        // now. Removing it outright would have meant touching every path that
        // still refers to it, for no gain.
        hud = NSTextField(labelWithString: "")
        hud.isHidden = true
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
        showNewGame()
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

        let gameItem = NSMenuItem()
        let gameMenu = NSMenu(title: "Game")
        let newGame = NSMenuItem(title: "New Game…",
                                 action: #selector(startNewGame), keyEquivalent: "n")
        newGame.target = self
        gameMenu.addItem(newGame)
        gameMenu.addItem(.separator())
        let apertureItem = NSMenuItem(title: "Aperture", action: nil, keyEquivalent: "")
        let apertureMenu = NSMenu(title: "Aperture")
        for mode in Aperture.allCases {
            let item = NSMenuItem(title: mode.rawValue,
                                  action: #selector(pickAperture(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            apertureMenu.addItem(item)
        }
        apertureItem.submenu = apertureMenu
        gameMenu.addItem(apertureItem)
        gameItem.submenu = gameMenu
        main.addItem(gameItem)

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
                              || tag == OriginalTiles.palette.rawValue
                              || tag == aperture.rawValue) ? .on : .off
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
            font = GameFont.load(in: destination)
            if report.historicalMap != nil { mapChoice = .historical }
            if newGameView != nil { showNewGame() } else { reload() }
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

    @objc private func startNewGame() { showNewGame() }

    @objc private func pickAperture(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = Aperture.allCases.first(where: { $0.rawValue == raw })
        else { return }
        aperture = mode
        // Live, not on reload: the explored mask keeps running under either
        // aperture, so there is nothing to rebuild — only the layout to redo and
        // the zoom to pin or release.
        shell.aperture = mode
        applyAperture()
        refreshChecks()
    }

    /// The two halves of an aperture: how wide the hole is, which is the shell's
    /// business, and what is drawn through it, which is the scene's.
    private func applyAperture() {
        scene?.fogEnabled = aperture == .explorer
        scene?.lockedTilesAcross = aperture == .classic ? Aperture.classicTiles : nil
        skView.frame = shell.viewportRect
    }

    // MARK: - New Game

    /// Put the New Game screen up over the map, and take the session down.
    ///
    /// The classic map is only offered when `historical.map` is actually there,
    /// so the screen has to be rebuilt each time rather than kept around — an
    /// import between one game and the next changes the answer.
    private func showNewGame() {
        newGameView?.removeFromSuperview()
        skView.isHidden = true
        shell.isHidden = true
        window.title = "Seven Cities of Gold"

        let haveClassic = FileManager.default.fileExists(
            atPath: assetDirectory.appendingPathComponent("historical.map").path)
        let view = NewGameView(haveClassicMap: haveClassic)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        view.onImportDisks = { [weak self] in self?.importDisks() }
        view.onChoice = { [weak self] choice in
            guard let self else { return }
            switch choice {
            case .classic:
                self.mapChoice = .historical
            case .random(let world):
                self.generated = WorldMap(world)
                self.mapChoice = .generated(seed: world.seed, config: world.config)
            }
            self.startSession()
        }
        container.addSubview(view)
        newGameView = view
        window.makeFirstResponder(view)
    }

    /// Take the New Game screen down and show the world it picked.
    private func startSession() {
        newGameView?.removeFromSuperview()
        newGameView = nil
        skView.isHidden = false
        shell.isHidden = false
        reload()
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
        // The New Game screen only offers the classic map when the file is
        // there, so this is the case where it went away between the choice and
        // the load. Going back to the screen is the only thing left to do.
        guard let map = loaded else {
            showNewGame()
            return
        }

        if originals == nil { originals = OriginalTiles.load(nextTo: url) }
        let haveOriginals = originals != nil
        let effective: TileStyle = (tileStyle == .original && !haveOriginals)
            ? .custom : tileStyle

        // The scene is built at the viewport's size, so the view has to be laid
        // out before the scene exists rather than after.
        skView.frame = shell.viewportRect
        let scene = WorldScene(map: map, style: effective,
                               originals: originals, size: skView.bounds.size)
        self.scene = scene
        scene.onStatusChange = { [weak self] lines in self?.shell.bottomLines = lines }
        scene.onMessage = { [weak self] text in
            guard let self else { return }
            // An empty message means the scene has nothing to announce, so the
            // line goes back to naming the world rather than going blank.
            shell.messageLine = text.isEmpty ? mapChoice.title.uppercased() : text
        }
        skView.presentScene(scene)
        applyAperture()
        window.makeFirstResponder(skView)

        var title = "Seven Cities — \(mapChoice.title) — \(effective.rawValue) tiles"
        if tileStyle == .original && !haveOriginals {
            title += "  (no original art — use File ▸ Import Disk Images…)"
        } else if effective == .original, let o = originals {
            let animated = o.tiles.count - o.patternCount
            title += "  (\(o.patternCount) original patterns, \(animated) animated)"
        }
        window.title = title

        // No game logic stands behind these yet, so they hold dashes. They are
        // here rather than left out because gold, food and crew get hooked up
        // behind these exact slots later.
        shell.dateLine = "MAY - 1492"
        shell.messageLine = mapChoice.title.uppercased()
        shell.leftPanel = [("MEN", "---"), ("FOOD", "---")]
        shell.rightPanel = [("GOODS", "---"), ("GOLD", "---")]
        refreshChecks()
    }
}
