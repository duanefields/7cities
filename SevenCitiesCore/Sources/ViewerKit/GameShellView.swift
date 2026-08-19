import AppKit
import SevenCitiesCore

/// The exploration screen's furniture, drawn the way the original draws it.
///
/// Everything except the map itself: the date and message lines, the four status
/// panels, the bottom lines, and the dithered frame around the viewport. The map
/// is not drawn here — ``viewportRect`` is the hole it goes in, and the owner
/// puts the SpriteKit view there.
///
/// ## What this is and is not
///
/// It is not a VIC-II. The original's screen is a fixed 40x25 grid of characters
/// at 320x200, and this is not: the aperture grows with the window, which was the
/// whole point of choosing fog of war over a six-tile porthole. What it keeps is
/// the original's palette, its charset, its layout and its frame — measured off a
/// captured screen rather than guessed:
///
/// | part | color |
/// | :--- | :---- |
/// | background | `$00` black |
/// | frame | `$07` yellow, dithered `10101010` over the black |
/// | date, message and status lines | `$07` yellow |
/// | panel labels | `$0E` light blue |
/// | panel values | `$07` yellow |
///
/// Those are sampled from a live exploration frame, not guessed. Reading them
/// off *color RAM* would have given black for every line, because the charset is
/// inverted: a glyph's ink is its zero bits, so the letters take `$D021` and the
/// background takes color RAM. The raster split at `$2250` then rewrites `$D021`
/// down the screen, which is how one color-RAM value yields several text colors.
///
/// The frame reads as an ornate olive band in the original for a reason worth
/// keeping: `$60` and `$61` are `AA` bytes top to bottom, and `$62`/`$63` are the
/// same dither in half a cell so the border hugs the viewport. Alternating yellow
/// and black pixels at 320 across is what the eye turns into olive.
/// How much world the window shows.
enum Aperture: String, CaseIterable, Sendable {
    /// The original's window: six map tiles square, and nothing outside it.
    ///
    /// This is the faithful setting, and the fog has no part in it. The C64's
    /// constraint was never darkness — every one of those thirty-six tiles is
    /// drawn, and what you cannot see is simply outside the hole. Because the
    /// aperture is fixed, the whole screen can be drawn at a much larger scale
    /// than the wide one allows, so this is chunky rather than cramped.
    case classic = "Classic (6x6 tiles)"
    /// A window as wide as the screen allows, with fog of war supplying the
    /// constraint the small hole used to. See `FogOfWar`.
    case explorer = "Explorer (fog of war)"

    /// The original's window in map tiles. Two characters to a tile.
    static let classicTiles = 6
}

@MainActor
final class GameShellView: NSView {

    // MARK: - What the owner fills in

    /// The top line, where the original puts the month and year.
    var dateLine = "" { didSet { needsDisplay = true } }
    /// The line under it, where the original announces discoveries.
    var messageLine = "" { didSet { needsDisplay = true } }
    /// Left panel, top and bottom. The original's MEN and FOOD.
    var leftPanel: [(label: String, value: String)] = [] { didSet { needsDisplay = true } }
    /// Right panel. The original's GOODS and GOLD.
    var rightPanel: [(label: String, value: String)] = [] { didSet { needsDisplay = true } }
    /// The two lines under the viewport.
    var bottomLines: [String] = [] { didSet { needsDisplay = true } }

    /// Called whenever the layout changes, with the new viewport rect, so the
    /// owner can move the map view into it.
    var onViewportChange: ((NSRect) -> Void)?

    private let font: GameFont?

    // MARK: - Layout

    /// Character cells reserved for a status panel, each side.
    ///
    /// Wide enough for GOODS and a four-digit value with a cell of air around
    /// them; everything left over goes to the viewport, which is where it is
    /// worth having.
    private static let panelCells = 10
    /// The original's 6x6 tiles, in character cells.
    private static let classicCells = Aperture.classicTiles * 2
    /// Cells above the viewport (blank, date, message, frame) and below it
    /// (frame, blank, two status lines).
    private static let cellsAbove = 4
    private static let cellsBelow = 5

    var aperture: Aperture = .classic { didSet { relayout() } }

    private(set) var scale = 3
    private var cell: CGFloat { CGFloat(8 * scale) }
    /// The viewport's interior, in cells — always even, since a map tile is two
    /// characters square.
    private var gridCells = (wide: 12, high: 12)
    private var gridOrigin = (col: 0, row: 0)

    init(font: GameFont?) {
        self.font = font
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize old: NSSize) {
        super.resizeSubviews(withOldSize: old)
        relayout()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        relayout()
    }

    /// Where the map goes: the interior of the frame, in this view's coordinates.
    private(set) var viewportRect: NSRect = .zero

    private func relayout() {
        // An integer scale throughout, because anything else resamples an 8x8
        // glyph and the charset stops being the charset.
        switch aperture {
        case .classic:
            // The grid is fixed, so the scale is free to be as large as the
            // window allows. That is the whole reason this mode is worth having
            // rather than being a smaller version of the other one: a six-tile
            // window on a modern display can be *big*.
            let colsNeeded = Self.panelCells * 2 + 2 + Self.classicCells
            let rowsNeeded = Self.cellsAbove + Self.cellsBelow + Self.classicCells
            scale = max(2, min(Int(bounds.width) / (colsNeeded * 8),
                               Int(bounds.height) / (rowsNeeded * 8)))
            gridCells = (Self.classicCells, Self.classicCells)
        case .explorer:
            // Floored against the original's own 320x200 so the layout always
            // has somewhere to sit; the grid then takes whatever is left.
            scale = max(2, min(Int(bounds.width / 320), Int(bounds.height / 200)))
            var wide = Int(bounds.width / cell) - Self.panelCells * 2 - 2
            var high = Int(bounds.height / cell) - Self.cellsAbove - Self.cellsBelow
            // The interior must be even in both directions to hold whole tiles.
            wide -= wide % 2
            high -= high % 2
            gridCells = (max(2, wide), max(2, high))
        }

        let cols = Int(bounds.width / cell)
        let rows = Int(bounds.height / cell)
        // Centered both ways, but never so high that the two lines above the
        // frame have nowhere to go. Everything else is placed relative to this,
        // so the block travels together rather than the text pinning to the top
        // while the frame floats in the middle.
        gridOrigin = (col: (cols - gridCells.wide) / 2,
                      row: max(Self.cellsAbove, (rows - gridCells.high) / 2))

        let x = CGFloat(gridOrigin.col) * cell
        let y = CGFloat(gridOrigin.row) * cell
        let rect = NSRect(x: x, y: y,
                          width: CGFloat(gridCells.wide) * cell,
                          height: CGFloat(gridCells.high) * cell)
        if rect != viewportRect {
            viewportRect = rect
            onViewportChange?(rect)
        }
        needsDisplay = true
    }

    // MARK: - Drawing

    private var palette: [NSColor] { OriginalTiles.c64 }
    private var background: NSColor { palette[0x00] }
    private var frameColor: NSColor { palette[0x07] }
    private var textColor: NSColor { palette[0x07] }
    private var labelColor: NSColor { palette[0x0E] }
    private var valueColor: NSColor { palette[0x07] }

    override func draw(_ dirty: NSRect) {
        background.setFill()
        dirty.fill()
        guard font != nil else {
            drawMissingFontNotice()
            return
        }

        let cols = Int(bounds.width / cell)
        let originCol = gridOrigin.col, originRow = gridOrigin.row

        // Date and message, centered on the whole screen the way the original
        // centers them — over the viewport rather than over a panel.
        draw(dateLine, centeredOn: cols / 2, row: originRow - 3, color: textColor)
        draw(messageLine, centeredOn: cols / 2, row: originRow - 2, color: textColor)

        drawFrame(originCol: originCol, originRow: originRow)

        // Panels, spaced down the viewport's height so they read as belonging to
        // it rather than floating in a margin.
        let leftCenter = originCol / 2
        let rightCenter = originCol + gridCells.wide + 1 + (cols - originCol - gridCells.wide - 1) / 2
        drawPanel(leftPanel, centeredOn: leftCenter, originRow: originRow)
        drawPanel(rightPanel, centeredOn: rightCenter, originRow: originRow)

        // Left-aligned to the viewport's left edge, not centered. The original
        // starts both of these at column 14, which is exactly where its map grid
        // begins — so the two labels line up with each other and with the frame.
        // Centering them independently makes SPEED and DEPTH ragged, since they
        // are different lengths.
        let below = originRow + gridCells.high + 2
        for (i, line) in bottomLines.enumerated() {
            draw(line, at: originCol, row: below + i, color: textColor)
        }
    }

    /// The four frame pieces, exactly as the original uses them: full-height
    /// dither down the sides, half-height along the top and bottom so the ink
    /// sits against the viewport rather than away from it.
    private func drawFrame(originCol: Int, originRow: Int) {
        guard let font else { return }
        let left = originCol - 1, right = originCol + gridCells.wide
        let top = originRow - 1, bottom = originRow + gridCells.high

        for row in originRow..<(originRow + gridCells.high) {
            draw(glyph: font.frameLeft, col: left, row: row, color: frameColor)
            draw(glyph: font.frameRight, col: right, row: row, color: frameColor)
        }
        for col in left...right {
            draw(glyph: font.frameTop, col: col, row: top, color: frameColor)
            draw(glyph: font.frameBottom, col: col, row: bottom, color: frameColor)
        }
    }

    private func drawPanel(_ entries: [(label: String, value: String)],
                           centeredOn col: Int, originRow: Int) {
        guard !entries.isEmpty else { return }
        // Spread the entries evenly down the viewport's height rather than
        // pinning them to fixed rows, so they stay put as the window grows.
        let span = gridCells.high
        for (i, entry) in entries.enumerated() {
            let row = originRow + (span * (2 * i + 1)) / (2 * entries.count) - 1
            draw(entry.label, centeredOn: col, row: row, color: labelColor)
            draw(entry.value, centeredOn: col, row: row + 2, color: valueColor)
        }
    }

    private func draw(_ text: String, centeredOn col: Int, row: Int, color: NSColor) {
        guard !text.isEmpty else { return }
        draw(text, at: col - text.count / 2, row: row, color: color)
    }

    private func draw(_ text: String, at col: Int, row: Int, color: NSColor) {
        guard let font else { return }
        for (i, character) in text.uppercased().enumerated() {
            guard let bitmap = font.glyph(character) else { continue }
            draw(glyph: bitmap, col: col + i, row: row, color: color)
        }
    }

    /// One 8x8 glyph, a set bit at a time. A set bit is ink; see ``GameFont``.
    private func draw(glyph: [UInt8], col: Int, row: Int, color: NSColor) {
        let ox = CGFloat(col) * cell, oy = CGFloat(row) * cell
        guard ox >= -cell, oy >= -cell, ox < bounds.width, oy < bounds.height else { return }
        color.setFill()
        let s = CGFloat(scale)
        let path = NSBezierPath()
        for y in 0..<8 {
            let bits = glyph[y]
            guard bits != 0 else { continue }
            var x = 0
            while x < 8 {
                guard bits & (0x80 >> UInt8(x)) != 0 else { x += 1; continue }
                // Runs rather than single pixels: the frame's dither is every
                // other pixel, but text is mostly solid, and one rect a run is a
                // fraction of the fill calls.
                var run = 1
                while x + run < 8, bits & (0x80 >> UInt8(x + run)) != 0 { run += 1 }
                path.appendRect(NSRect(x: ox + CGFloat(x) * s, y: oy + CGFloat(y) * s,
                                       width: CGFloat(run) * s, height: s))
                x += run
            }
        }
        path.fill()
    }

    private func drawMissingFontNotice() {
        let text = "Import your disk images to see the original screen"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 30),
            withAttributes: attributes)
    }
}

extension GameFont {
    /// Read `font.json` out of an asset directory, or `nil` if it is not there —
    /// which is the ordinary state before any disk has been imported.
    static func load(in directory: URL) -> GameFont? {
        let url = directory.appendingPathComponent("font.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? GameFont(json: data)
    }
}
