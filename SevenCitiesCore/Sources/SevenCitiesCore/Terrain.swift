/// A single map tile.
///
/// The original packs two tiles per byte as nibbles, so there are exactly 16
/// values. Names follow the game's own vocabulary, recovered from its terrain
/// name table at `$1566`: DEEP, MEDIUM, SHALLOW, SHIP, RIVER, PLAIN, FOREST,
/// MOUNTAIN, SWAMP, VILLAGE.
///
/// The original collapses all seven river values to one class when naming
/// terrain, but keeps them distinct in map data because each encodes which two
/// neighbours the river connects to.
public enum Terrain: UInt8, CaseIterable, Sendable {
    case deepWater = 0x0
    case mediumWater = 0x1
    case shallowWater = 0x2
    case ship = 0x3
    case riverJunction = 0x4
    case riverWE = 0x5
    case riverNW = 0x6
    case riverSW = 0x7
    case riverNS = 0x8
    case riverNE = 0x9
    case riverSE = 0xA
    case plain = 0xB
    case forest = 0xC
    case mountain = 0xD
    case swamp = 0xE
    case village = 0xF

    /// The name the original would show on its `TERRAIN:` status line.
    public var displayName: String {
        switch self {
        case .deepWater: "DEEP"
        case .mediumWater: "MEDIUM"
        case .shallowWater: "SHALLOW"
        case .ship: "SHIP"
        case .riverJunction, .riverWE, .riverNW, .riverSW,
             .riverNS, .riverNE, .riverSE: "RIVER"
        case .plain: "PLAIN"
        case .forest: "FOREST"
        case .mountain: "MOUNTAIN"
        case .swamp: "SWAMP"
        case .village: "VILLAGE"
        }
    }

    public var isWater: Bool {
        switch self {
        case .deepWater, .mediumWater, .shallowWater: true
        default: false
        }
    }

    public var isRiver: Bool {
        switch self {
        case .riverJunction, .riverWE, .riverNW, .riverSW,
             .riverNS, .riverNE, .riverSE: true
        default: false
        }
    }

    /// Land you can stand on. Rivers count — they are the fast route inland,
    /// which the manual stresses.
    public var isLand: Bool { !isWater }

    /// Which neighbours a river tile links to.
    ///
    /// The six two-way masks are exactly the ways to choose 2 of 4 directions.
    /// A junction links to all four; everything else links to nothing.
    public var riverConnections: Set<Direction> {
        switch self {
        case .riverWE: [.west, .east]
        case .riverNS: [.north, .south]
        case .riverNW: [.north, .west]
        case .riverSW: [.south, .west]
        case .riverNE: [.north, .east]
        case .riverSE: [.south, .east]
        case .riverJunction: [.north, .south, .east, .west]
        default: []
        }
    }
}

public enum Direction: CaseIterable, Sendable {
    case north, south, east, west

    public var offset: (dx: Int, dy: Int) {
        switch self {
        case .north: (0, -1)
        case .south: (0, 1)
        case .east: (1, 0)
        case .west: (-1, 0)
        }
    }
}
