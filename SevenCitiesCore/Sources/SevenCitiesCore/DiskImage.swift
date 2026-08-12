import Foundation

/// A Commodore 1541 disk image (`.d64`), 35 tracks, 174,848 bytes.
public struct DiskImage: Sendable {

    public let bytes: [UInt8]

    public enum LoadError: Error, CustomStringConvertible {
        case wrongSize(Int)
        public var description: String {
            switch self {
            case .wrongSize(let n):
                "not a 35-track .d64: expected 174848 bytes, got \(n)"
            }
        }
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        // 174848 is a plain 35-track image; 175531 carries error bytes we ignore.
        guard data.count == 174_848 || data.count == 175_531 else {
            throw LoadError.wrongSize(data.count)
        }
        self.bytes = [UInt8](data.prefix(174_848))
    }

    public static func sectorsPerTrack(_ track: Int) -> Int {
        switch track {
        case 1...17: 21
        case 18...24: 19
        case 25...30: 18
        default: 17
        }
    }

    public func sector(track: Int, sector: Int) -> ArraySlice<UInt8> {
        var offset = 0
        for t in 1..<track { offset += Self.sectorsPerTrack(t) * 256 }
        offset += sector * 256
        return bytes[offset..<(offset + 256)]
    }

    /// The disk name from the BAM, for identifying which side an image is.
    public var diskName: String {
        let bam = sector(track: 18, sector: 0)
        let start = bam.startIndex + 0x90
        return String(bam[start..<(start + 16)]
            .filter { $0 != 0xA0 }
            .map { Character(UnicodeScalar($0 >= 0xC1 && $0 <= 0xDA ? $0 - 0x80 : $0)) })
    }

    /// Directory entry count, which is how the game tells a map disk from a
    /// program disk: a real map disk has none.
    public var directoryEntryCount: Int {
        var count = 0
        var (t, s) = (18, 1)
        var seen = Set<Int>()
        while t != 0, !seen.contains(t * 100 + s) {
            seen.insert(t * 100 + s)
            let sec = sector(track: t, sector: s)
            for i in 0..<8 where sec[sec.startIndex + i * 32 + 2] != 0 { count += 1 }
            (t, s) = (Int(sec[sec.startIndex]), Int(sec[sec.startIndex + 1]))
        }
        return count
    }
}
