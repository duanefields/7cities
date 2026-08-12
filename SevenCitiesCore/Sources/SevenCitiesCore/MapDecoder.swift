import Foundation

/// Decodes a map disk into a flat tile grid.
///
/// Four things all have to be right at once, and each was got wrong at least
/// once while working this out:
///
/// 1. The fastloader only ever reads **sectors 0-19** of each track. Tracks
///    1-17 hold 21, so dumping in naive physical order inserts a stray sector
///    per track and destroys alignment downstream.
/// 2. Each 256-byte sector is a **16x16 block**, not a row.
/// 3. Blocks tile **8 per row** — the source row stride is `$80` = 128 tiles
///    and a block is 16 wide. Using 16 produces a visibly doubled map.
/// 4. A sector is **not row-major inside the block**: bytes `$00-$7F` are the
///    left 8 columns of all 16 rows, `$80-$FF` the right 8.
///
/// Then every byte holds **two tiles as nibbles**, high nibble first, so the
/// finished map is 256 wide.
public enum MapDecoder {

    static let block = 16
    static let blocksPerRow = 8
    static let padding: UInt8 = 0x01
    /// The stream starts one block before the map's true left edge.
    static let rollBlocks = 1

    public enum DecodeError: Error, CustomStringConvertible {
        case noTerrainFound
        public var description: String {
            "no terrain rows found — is this actually a map disk?"
        }
    }

    public static func decode(_ disk: DiskImage,
                              firstTrack: Int = 13) throws -> WorldMap {
        // 1. sectors in loader order
        var sectors: [ArraySlice<UInt8>] = []
        for t in firstTrack...35 {
            let count = min(20, DiskImage.sectorsPerTrack(t))
            for s in 0..<count { sectors.append(disk.sector(track: t, sector: s)) }
        }

        // 2 + 3 + 4. un-block into packed bytes
        let rows = (sectors.count + blocksPerRow - 1) / blocksPerRow
        let w = blocksPerRow * block
        let h = rows * block
        var packed = [UInt8](repeating: padding, count: w * h)
        for (i, sec) in sectors.enumerated() {
            let bx = (i % blocksPerRow) * block
            let by = (i / blocksPerRow) * block
            let base = sec.startIndex
            for r in 0..<block {
                let dst = (by + r) * w + bx
                for c in 0..<8 {
                    packed[dst + c] = sec[base + r * 8 + c]
                    packed[dst + 8 + c] = sec[base + 0x80 + r * 8 + c]
                }
            }
        }

        // crop to the longest contiguous run of terrain rows: both disks carry
        // other structures outside the map, and spanning min..max swallows them
        func isMapRow(_ by: Int) -> Bool {
            var terrain = 0
            for r in 0..<block {
                for x in 0..<w {
                    let v = packed[(by + r) * w + x]
                    let hi = v >> 4, lo = v & 0x0F
                    for n in [hi, lo] where n == 0 || (n >= 0xB && n <= 0xE) { terrain += 1 }
                }
            }
            return Double(terrain) / Double(block * w * 2) > 0.75
        }
        var best: (Int, Int)?
        var run: (Int, Int)?
        for by in stride(from: 0, to: h, by: block) {
            if isMapRow(by) {
                run = (run?.0 ?? by, by)
                if best == nil || (run!.1 - run!.0) > (best!.1 - best!.0) { best = run }
            } else {
                run = nil
            }
        }
        guard let keep = best else { throw DecodeError.noTerrainFound }
        let top = keep.0, height = keep.1 + block - top

        // 5. roll left one block, then split nibbles
        let dx = (rollBlocks * block) % w
        var tiles = [Terrain](repeating: .deepWater, count: w * 2 * height)
        for y in 0..<height {
            let src = (top + y) * w
            for x in 0..<w {
                let v = packed[src + (x + dx) % w]
                tiles[y * w * 2 + x * 2] = Terrain(rawValue: v >> 4) ?? .deepWater
                tiles[y * w * 2 + x * 2 + 1] = Terrain(rawValue: v & 0x0F) ?? .deepWater
            }
        }
        return WorldMap(width: w * 2, height: height, tiles: tiles)
    }
}
