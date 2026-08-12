import Foundation

/// Turns disk images the user owns into the files the viewer reads.
///
/// Factored out of the `Extract` command so the app can run the same code from
/// a menu item — nobody should have to open a terminal to use their own disks.
/// No game data ships with this project; everything here reads images the user
/// supplies and writes derived files into a directory they choose.
public enum AssetExtractor {

    public struct Report: Sendable {
        public var historicalMap: (width: Int, height: Int)?
        public var terrainPatterns: Int?
        public var animatedTiles: Int?
        public var notes: [String] = []

        public var wroteAnything: Bool { historicalMap != nil || terrainPatterns != nil }

        /// A short human summary, for a CLI line or an alert body.
        public var summary: String {
            var parts: [String] = []
            if let m = historicalMap { parts.append("classic map \(m.width)x\(m.height)") }
            if let p = terrainPatterns {
                parts.append("\(p) terrain patterns" + (animatedTiles.map { " + \($0) animated" } ?? ""))
            }
            return parts.isEmpty ? "nothing extracted" : parts.joined(separator: ", ")
        }
    }

    public enum ExtractError: Error, CustomStringConvertible {
        case noDisksFound(String)
        public var description: String {
            switch self {
            case .noDisksFound(let where_):
                "no Seven Cities disk images found in \(where_)"
            }
        }
    }

    /// Identifies a disk image by reading it, rather than trusting its filename.
    ///
    /// Filenames vary wildly between dumps, and side 2 is distinguishable on
    /// content: side 1 carries a file named `game`, side 2 does not.
    public static func classify(_ url: URL) -> (isSide1: Bool, disk: DiskImage)? {
        guard let disk = try? DiskImage(contentsOf: url) else { return nil }
        let hasGame = disk.directory.contains {
            $0.name.caseInsensitiveCompare("game") == .orderedSame
        }
        return (hasGame, disk)
    }

    /// Extracts everything obtainable from the given disk images.
    ///
    /// `images` may be in any order and may be a single disk; whatever can be
    /// read is written, and the rest is reported as a note rather than an error.
    public static func extract(images: [URL], to outputDirectory: URL) throws -> Report {
        var report = Report()
        try FileManager.default.createDirectory(at: outputDirectory,
                                                withIntermediateDirectories: true)

        var side1: [DiskImage] = []
        var side2: [DiskImage] = []
        for url in images {
            guard let (isSide1, disk) = classify(url) else {
                report.notes.append("\(url.lastPathComponent): not a 35-track .d64")
                continue
            }
            if isSide1 { side1.append(disk) } else { side2.append(disk) }
        }
        guard !side1.isEmpty || !side2.isEmpty else {
            throw ExtractError.noDisksFound(outputDirectory.path)
        }

        // A folder can hold more than one map disk — the World Maker writes
        // blank ones, and they classify identically to the real thing. Taking
        // whichever the filesystem happened to list last would sometimes
        // extract an empty world, so decode every candidate and keep the one
        // with the most land.
        let decoded = side2.compactMap { try? MapDecoder.decode($0) }
        let best = decoded.max { a, b in landCount(a) < landCount(b) }
        if let map = best, landCount(map) > 0 {
            do {
                try map.write(to: outputDirectory.appendingPathComponent("historical.map"))
                report.historicalMap = (map.width, map.height)
                if decoded.count > 1 {
                    report.notes.append("\(decoded.count) map disks supplied; kept the one with the most land")
                }
            } catch {
                report.notes.append("could not write the classic map: \(error)")
            }
        } else if side2.isEmpty {
            report.notes.append("side 2 not supplied — the classic map is unavailable")
        } else {
            report.notes.append("the map disk supplied is blank — no land on it")
        }

        if let disk = side1.first {
            do {
                let art = try TerrainTiles(programDisk: disk)
                let json = terrainTilesJSON(art)
                try json.write(to: outputDirectory.appendingPathComponent("original_tiles.json"),
                               atomically: true, encoding: .utf8)
                let drawn = art.tiles.values.filter { !$0.isAnimated }.count
                report.terrainPatterns = drawn
                report.animatedTiles = art.tiles.count - drawn
            } catch {
                report.notes.append("could not read the terrain art: \(error)")
            }
        } else {
            report.notes.append("side 1 not supplied — the original terrain art is unavailable")
        }

        return report
    }

    private static func landCount(_ map: WorldMap) -> Int {
        var n = 0
        for y in 0..<map.height {
            for x in 0..<map.width where map[x, y].isLand { n += 1 }
        }
        return n
    }

    /// A tiny hand-rolled encoder. The shape is fixed, and keeping the asset
    /// readable matters when the whole point is that a user can see what came
    /// off their own disk.
    public static func terrainTilesJSON(_ art: TerrainTiles) -> String {
        let p = TerrainTiles.palette
        var json = "{\n"
        json += "  \"palette\": { \"land\": \(p.land), \"water\": \(p.water), "
        json += "\"vegetation\": \(p.vegetation), \"detail\": \(p.detail) },\n"
        json += "  \"width\": \(TerrainTiles.width), \"height\": \(TerrainTiles.height),\n"
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
        return json + entries.joined(separator: ",\n") + "\n  }\n}\n"
    }

    /// Where the app keeps extracted assets, so a bundled app needs no
    /// command-line arguments and no fixed working directory.
    public static var defaultAssetDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support.appendingPathComponent("SevenCities/assets", isDirectory: true)
    }
}
