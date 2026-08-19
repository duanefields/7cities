import Foundation

/// The game's own 8x8 character set, read straight off disk 1.
///
/// The exploration screen draws everything that is not terrain out of this: the
/// date, the message line, the status panels, and the four pieces of the
/// viewport frame. It is **not** the Commodore ROM charset — the game carries
/// its own, in ASCII order from space rather than in PETSCII order, which is why
/// its text tables index it as `character = ASCII - $20`.
///
/// That it is the game's own is what makes the whole styled shell possible
/// without a font license: it comes off the user's disk exactly as the terrain
/// tiles do, and like them it is never committed.
///
/// ## Where it lives
///
/// At offset 4713 of the raw stream of tracks 1 to 10, sectors 0 to 19 — the
/// loader only ever reads twenty sectors a track, so a stream built any other
/// way puts every offset after track 1 in the wrong place. Ninety-six glyphs,
/// then five more that are the viewport frame.
///
/// ## Ink and paper
///
/// On disk a set bit is the letter's ink. The running game holds the inverse:
/// `$0CEB` fills a charset buffer and what lands at `$A000` is this data EOR
/// `$FF` — measured, 94 of 96 glyphs exactly. Nothing here reproduces that,
/// because nothing here is a VIC-II: a set bit is ink and the renderer draws it
/// in whatever color the screen asks for.
public struct GameFont: Sendable {

    /// Where the font starts in the tracks 1-10 stream. Ground-truthed against a
    /// charset dumped from the running game.
    static let fontOffset = 4713
    static let glyphCount = 96
    /// The lowest character the font covers. Everything is indexed off it.
    public static let firstCharacter: UInt8 = 0x20

    /// Ninety-six glyphs in ASCII order from space, eight bytes each, MSB left.
    public var glyphs: [[UInt8]]

    /// The viewport frame, charset codes `$60`-`$64`, in the order the screen
    /// uses them. They sit immediately after the font on disk.
    ///
    /// The frame really is this plain: one repeated glyph an edge. What makes it
    /// read as ornate in the original is the color it is drawn in, not the
    /// shapes.
    public var frameLeft: [UInt8]      // $60
    public var frameRight: [UInt8]     // $61
    public var frameBottom: [UInt8]    // $62
    public var frameTop: [UInt8]       // $63
    /// `$64`, which follows the other four. Kept because it is part of the same
    /// static block and the screen may yet turn out to use it.
    public var frameExtra: [UInt8]

    /// Four of the ninety-six are blank on disk: space, which should be, and
    /// `?`, `n` and `o`, which should not — the running game has real glyphs at
    /// all three. Whatever fills them happens somewhere this has not followed,
    /// so text containing them will come out with holes.
    public static let blankOnDisk: [Character] = ["?", "n", "o"]

    /// The glyph for an ASCII character, or `nil` outside the font's range.
    public func glyph(_ character: Character) -> [UInt8]? {
        guard let ascii = character.asciiValue,
              ascii >= Self.firstCharacter,
              Int(ascii - Self.firstCharacter) < glyphs.count
        else { return nil }
        return glyphs[Int(ascii - Self.firstCharacter)]
    }

    public enum FontError: Error, CustomStringConvertible {
        case tooShort
        case notTheFont(lettersFound: Int)

        public var description: String {
            switch self {
            case .tooShort:
                "disk 1 is too short to hold the font — is this the right side?"
            case .notTheFont(let n):
                "only \(n) of 26 letters look like glyphs at offset "
                    + "\(GameFont.fontOffset) — this is not disk 1's font"
            }
        }
    }

    /// The raw stream the font's offset is measured in: tracks 1 to 10, twenty
    /// sectors each, in order.
    static func rawStream(of disk: DiskImage) -> [UInt8] {
        var stream: [UInt8] = []
        stream.reserveCapacity(10 * 20 * 256)
        for track in 1...10 {
            for sector in 0..<20 {
                stream.append(contentsOf: disk.sector(track: track, sector: sector))
            }
        }
        return stream
    }

    /// Read the font and the frame out of disk 1.
    public static func extract(from disk: DiskImage) throws -> GameFont {
        let stream = rawStream(of: disk)
        let needed = fontOffset + (glyphCount + 5) * 8
        guard stream.count >= needed else { throw FontError.tooShort }

        func glyph(_ index: Int) -> [UInt8] {
            let start = fontOffset + index * 8
            return Array(stream[start..<start + 8])
        }
        let glyphs = (0..<glyphCount).map(glyph)

        // Check the offset rather than trusting it. A letter has ink in its
        // middle rows and a clear bottom row; if twenty of the twenty-six do not,
        // this is not the font and every glyph after it would be garbage.
        let letters = (33..<59).filter {
            glyphs[$0][7] == 0 && glyphs[$0][1..<7].contains { $0 != 0 }
        }.count
        guard letters >= 20 else { throw FontError.notTheFont(lettersFound: letters) }

        return GameFont(glyphs: glyphs,
                        frameLeft: glyph(glyphCount),
                        frameRight: glyph(glyphCount + 1),
                        frameBottom: glyph(glyphCount + 2),
                        frameTop: glyph(glyphCount + 3),
                        frameExtra: glyph(glyphCount + 4))
    }

    // MARK: - On disk, beside the map and the tiles

    public init(glyphs: [[UInt8]], frameLeft: [UInt8], frameRight: [UInt8],
                frameBottom: [UInt8], frameTop: [UInt8], frameExtra: [UInt8]) {
        self.glyphs = glyphs
        self.frameLeft = frameLeft
        self.frameRight = frameRight
        self.frameBottom = frameBottom
        self.frameTop = frameTop
        self.frameExtra = frameExtra
    }

    /// The extracted form, as JSON, so the viewer needs neither a disk image nor
    /// the extractor at run time.
    public var json: String {
        func row(_ bytes: [UInt8]) -> String {
            "[" + bytes.map(String.init).joined(separator: ",") + "]"
        }
        let entries = glyphs.enumerated().map { index, bytes in
            "    \"\(Self.firstCharacter + UInt8(index))\": \(row(bytes))"
        }
        return """
        {
          "order": "ASCII from space; index = ASCII - 32",
          "glyphs": {
        \(entries.joined(separator: ",\n"))
          },
          "frame": {
            "left": \(row(frameLeft)),
            "right": \(row(frameRight)),
            "bottom": \(row(frameBottom)),
            "top": \(row(frameTop)),
            "extra": \(row(frameExtra))
          }
        }
        """
    }

    /// Read back what ``json`` wrote.
    public init(json data: Data) throws {
        struct Wire: Decodable {
            var glyphs: [String: [UInt8]]
            var frame: [String: [UInt8]]
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        glyphs = (0..<Self.glyphCount).map {
            wire.glyphs[String(Self.firstCharacter + UInt8($0))] ?? [UInt8](repeating: 0, count: 8)
        }
        let blank = [UInt8](repeating: 0, count: 8)
        frameLeft = wire.frame["left"] ?? blank
        frameRight = wire.frame["right"] ?? blank
        frameBottom = wire.frame["bottom"] ?? blank
        frameTop = wire.frame["top"] ?? blank
        frameExtra = wire.frame["extra"] ?? blank
    }
}
