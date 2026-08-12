import AppKit
import SevenCitiesCore
import ViewerKit

// The command-line front end. It exists so the viewer can be run and dumped
// headlessly straight from `swift run`, with no app bundle; the Xcode app
// target wraps the same `ViewerKit` in a real bundle. All the behavior lives in
// the library, so the two cannot drift apart.
//
//     MapViewer [<assets>] [--dump <out.png> [historical|generated]
//                                            [original|custom] [--gen <seed>]]

nonisolated(unsafe) var delegateBox: AnyObject?

let args = CommandLine.arguments
let positional = args.dropFirst().first { !$0.hasPrefix("--") }
let assets = positional.map { URL(fileURLWithPath: $0) }
    ?? AssetExtractor.defaultAssetDirectory

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
