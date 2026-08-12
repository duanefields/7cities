import Foundation
import SevenCitiesCore

// One command that turns your own disk images into everything the viewer
// needs. No emulator, no Python.

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1
               ? CommandLine.arguments[1] : fm.currentDirectoryPath)
let diskDir = root.appendingPathComponent("d64")
let outDir = root.appendingPathComponent("assets")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

@MainActor
func findDisk(named wanted: String) -> URL? {
    guard let entries = try? fm.contentsOfDirectory(at: diskDir,
                                                    includingPropertiesForKeys: nil)
    else { return nil }
    if let exact = entries.first(where: {
        $0.lastPathComponent.caseInsensitiveCompare(wanted) == .orderedSame
    }) { return exact }
    // be forgiving about naming, e.g. "Seven Cities of Gold (Side 2).d64"
    let hint = wanted.contains("2") ? "2" : "1"
    return entries.first {
        $0.pathExtension.caseInsensitiveCompare("d64") == .orderedSame
            && $0.deletingPathExtension().lastPathComponent.hasSuffix(hint)
    }
}

guard fm.fileExists(atPath: diskDir.path) else {
    fail("""
    No d64 folder found at \(diskDir.path)

    Create it and add your own Seven Cities of Gold disk images:

        d64/7CITIES1.D64    program disk, side 1
        d64/7CITIES2.D64    program disk, side 2 (the historical map)

    No game data ships with this project — you need images of disks you own.
    """)
}

guard let side2 = findDisk(named: "7CITIES2.D64") else {
    fail("""
    Could not find 7CITIES2.D64 in \(diskDir.path)

    Side 2 holds the historical map of the Americas. Without it the viewer can
    still generate worlds, but the classic map will be unavailable.
    """)
}

try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

do {
    let disk = try DiskImage(contentsOf: side2)
    print("side 2: \(side2.lastPathComponent)  name '\(disk.diskName)'  "
          + "\(disk.directoryEntryCount) directory entries")
    let map = try MapDecoder.decode(disk)
    let dest = outDir.appendingPathComponent("historical.map")
    try map.write(to: dest)

    var counts: [Terrain: Int] = [:]
    for y in 0..<map.height {
        for x in 0..<map.width { counts[map[x, y], default: 0] += 1 }
    }
    print("historical map: \(map.width)x\(map.height) -> \(dest.path)")
    for t in Terrain.allCases where (counts[t] ?? 0) > 0 {
        let n = counts[t]!
        let pct = 100.0 * Double(n) / Double(map.width * map.height)
        print("  \(t)".padding(toLength: 20, withPad: " ", startingAt: 0)
              + String(format: "%6d  %5.1f%%", n, pct))
    }
} catch {
    fail("could not decode \(side2.lastPathComponent): \(error)")
}

if let side1 = findDisk(named: "7CITIES1.D64") {
    print("side 1: \(side1.lastPathComponent) found")
    do {
        let disk = try DiskImage(contentsOf: side1)
        let art = try TerrainTiles(programDisk: disk)

        // A tiny hand-rolled encoder: the shape is fixed and this keeps the
        // asset readable, which matters when the whole point is that a user can
        // see what came off their own disk.
        var json = "{\n"
        let p = TerrainTiles.palette
        json += "  \"palette\": { \"land\": \(p.land), \"water\": \(p.water), "
        json += "\"vegetation\": \(p.vegetation), \"detail\": \(p.detail) },\n"
        json += "  \"width\": \(TerrainTiles.width), "
        json += "\"height\": \(TerrainTiles.height),\n"
        json += "  \"tiles\": {\n"
        let entries = Terrain.allCases.compactMap { t -> String? in
            guard let tile = art.tiles[t] else { return nil }
            let rows = tile.pixels
                .map { "[" + $0.map(String.init).joined(separator: ",") + "]" }
                .joined(separator: ",\n        ")
            return """
                  "\(t)": {
                    "address": \(tile.address),
                    "animated": \(tile.isAnimated),
                    "pixels": [
                        \(rows)
                    ]
                  }
            """
        }
        json += entries.joined(separator: ",\n") + "\n  }\n}\n"

        let dest = outDir.appendingPathComponent("original_tiles.json")
        try json.write(to: dest, atomically: true, encoding: .utf8)
        let drawn = art.tiles.values.filter { !$0.isAnimated }.count
        print("terrain tiles: \(drawn) patterns + "
              + "\(art.tiles.count - drawn) animated -> \(dest.path)")
    } catch {
        print("note: could not read the terrain tiles (\(error)) — "
              + "the viewer will fall back to custom art")
    }
} else {
    print("note: 7CITIES1.D64 not found — only side 2 is needed for the classic map")
    print("      side 1 also carries the original terrain art")
}
print("\ndone — run the viewer with:  swift run MapViewer assets")
