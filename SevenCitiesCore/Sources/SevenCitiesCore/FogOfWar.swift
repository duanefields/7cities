/// What the expedition has seen, a cell at a time.
///
/// The original shows the world through a six-tile window and remembers nothing
/// from frame to frame — but it *does* remember what has been discovered, which
/// its discovery screen proves: LAND, RIVERS, NATIVES, MINES and SPECIAL are
/// reported as percentages found, and none of those is computable without a
/// per-cell record. This is that record, used for two things at once: the
/// aperture you see through, and the map that fills in behind you.
///
/// ## Why the radius is three
///
/// The original's window is 6x6 tiles (`$3107`), and that window is the whole of
/// its information constraint — you know what is next to you and nothing else.
/// Keeping the *radius* at the window's reach while letting the drawn area grow
/// with the screen means nothing is ever revealed that the C64 would not have
/// revealed. The extra room on a modern display buys memory, not vision.
///
/// Chebyshev rather than Euclidean, because the original's aperture is a square
/// window and not a circle of sight: at radius 3 that is the 7x7 block centered
/// on the expedition. Nothing occludes anything in an open ocean, so there is no
/// shadowcasting here and none is wanted.
public struct FogOfWar: Sendable {

    /// How a cell should be drawn.
    public enum Visibility: Sendable, Equatable {
        /// Never been near it. The map does not show it at all.
        case unseen
        /// Seen once and left behind. Drawn, but dimmed.
        case remembered
        /// Within sight now. Drawn at full strength.
        case visible
    }

    /// The original's 6x6 aperture, as a radius. See the note above.
    public static let sightRadius = 3

    public let width: Int
    public let height: Int

    /// One bit a cell, in row-major order, top-down like ``WorldMap``.
    private var seen: [Bool]

    /// Where the expedition is, or `nil` before it has been placed — in which
    /// case nothing is `visible` and only memory shows.
    public private(set) var eye: (x: Int, y: Int)?

    /// How many cells have ever been seen. The numerator of every percentage on
    /// the discovery screen.
    public private(set) var exploredCount = 0

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.seen = [Bool](repeating: false, count: width * height)
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    /// Whether a cell has ever been within sight, whatever it is now.
    public func isExplored(x: Int, y: Int) -> Bool {
        guard contains(x: x, y: y) else { return false }
        return seen[y * width + x]
    }

    public func visibility(x: Int, y: Int) -> Visibility {
        guard isExplored(x: x, y: y) else { return .unseen }
        guard let eye else { return .remembered }
        let far = max(abs(x - eye.x), abs(y - eye.y))
        return far <= Self.sightRadius ? .visible : .remembered
    }

    /// Move the expedition and reveal everything within sight of where it now
    /// stands.
    ///
    /// - Returns: how many cells this uncovered that were not already known,
    ///   which is zero for most steps once you are retracing your own path.
    @discardableResult
    public mutating func look(from position: (x: Int, y: Int)) -> Int {
        eye = position
        let r = Self.sightRadius
        var uncovered = 0
        for y in max(0, position.y - r)...min(height - 1, position.y + r) {
            for x in max(0, position.x - r)...min(width - 1, position.x + r) {
                let i = y * width + x
                if !seen[i] {
                    seen[i] = true
                    uncovered += 1
                    exploredCount += 1
                }
            }
        }
        return uncovered
    }

    /// The share of the world that has been seen, 0 to 1.
    public var exploredFraction: Double {
        Double(exploredCount) / Double(width * height)
    }
}
