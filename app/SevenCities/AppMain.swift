import AppKit
import SevenCitiesCore
import ViewerKit

// The Mac app is deliberately thin: it owns the bundle, the menu bar and the
// launch, and nothing else. Every behavior lives in `ViewerKit`, which the
// `MapViewer` command also uses, so the two front ends cannot drift apart.
//
// Assets default to Application Support, so a user who double-clicks the app
// never has to pass a path or edit a scheme. With none present the viewer
// generates a world, and `File ▸ Import Disk Images…` extracts the classic map
// and the original art from disks they own.

@main
enum SevenCitiesApp {
    static func main() {
        let app = NSApplication.shared
        let controller = ViewerController(
            assetDirectory: AssetExtractor.defaultAssetDirectory)
        app.delegate = controller
        app.setActivationPolicy(.regular)
        // Held for the process lifetime; NSApplication's delegate is weak.
        delegate = controller
        app.run()
    }

    nonisolated(unsafe) private static var delegate: AnyObject?
}
