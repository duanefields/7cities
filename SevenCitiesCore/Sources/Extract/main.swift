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

guard fm.fileExists(atPath: diskDir.path) else {
    fail("""
    No d64 folder found at \(diskDir.path)

    Create it and add your own Seven Cities of Gold disk images:

        d64/7CITIES1.D64    program disk, side 1
        d64/7CITIES2.D64    program disk, side 2 (the historical map)

    No game data ships with this project — you need images of disks you own.
    """)
}

let images = (try? fm.contentsOfDirectory(at: diskDir, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension.caseInsensitiveCompare("d64") == .orderedSame } ?? []

guard !images.isEmpty else {
    fail("""
    No disk images in \(diskDir.path)

    Add images of disks you own:

        d64/7CITIES1.D64    program disk, side 1 — the terrain art
        d64/7CITIES2.D64    program disk, side 2 — the historical map

    No game data ships with this project.
    """)
}

do {
    // Same code the app runs from its File menu, so the two cannot diverge.
    let report = try AssetExtractor.extract(images: images, to: outDir)
    for url in images {
        if let (isSide1, disk) = AssetExtractor.classify(url) {
            print("\(url.lastPathComponent): side \(isSide1 ? 1 : 2), "
                  + "name '\(disk.diskName)', \(disk.directoryEntryCount) directory entries")
        }
    }
    print(report.summary + " -> \(outDir.path)")
    for note in report.notes { print("  note: \(note)") }
    if !report.wroteAnything { exit(1) }
} catch {
    fail("could not extract: \(error)")
}

print("\ndone — run the viewer with:  make run")
