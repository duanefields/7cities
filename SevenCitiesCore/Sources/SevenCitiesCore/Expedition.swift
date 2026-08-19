/// Where the expedition is, and the rules for moving it.
///
/// Landing, walking and re-embarking are game rules rather than view code, so
/// they live here where they can be tested instead of clicked. `WorldScene`
/// draws whatever this says and contributes no rules of its own.
///
/// There is no pace, no terrain cost and no supply here — none of that is in
/// this harness. What is here is the whole of how the expedition gets from a
/// ship at sea to a party on a continent and back again.
public struct Expedition: Sendable {

    public enum Mode: Sendable, Equatable {
        /// The party is aboard, and the expedition is the ship.
        case aboard
        /// The party is ashore and the ship waits at ``ship``.
        case ashore
    }

    /// What a step did, so the caller can say so without re-deriving it.
    public enum Outcome: Sendable, Equatable {
        case sailed
        case walked
        /// Stepped off the ship onto land. The ship stays where it was.
        case landed
        /// Stepped back onto the ship's own tile.
        case boarded
        case blocked(Reason)

        /// Why a step was refused. A reason rather than a sentence, because the
        /// wording is the screen's business and the rule is this type's.
        public enum Reason: Sendable, Equatable {
            case offMap
            /// A party ashore stepped at water that is not the ship's tile.
            case partyCannotSwim
        }
    }

    /// Where the expedition is: the ship at sea, the party ashore.
    public private(set) var position: (x: Int, y: Int)
    /// Where the ship is. The same as ``position`` while aboard.
    public private(set) var ship: (x: Int, y: Int)
    public private(set) var mode: Mode

    /// Start at sea, aboard, which is how the original begins.
    public init(atSea position: (x: Int, y: Int)) {
        self.position = position
        self.ship = position
        self.mode = .aboard
    }

    public var isAshore: Bool { mode == .ashore }

    /// One step in one of the eight directions.
    ///
    /// The two rules that are not simply "stay on your own terrain" are what
    /// make the harness work, and both are deliberate:
    ///
    /// - Aboard, stepping at **land** is not refused — it *is* the landing. The
    ///   ship moors on the water it is already floating on and the party walks
    ///   ashore. There is no separate "land" command, exactly as there is none
    ///   in the original.
    /// - Ashore, stepping at the **ship's own tile** re-boards it. Every other
    ///   water tile is refused, so the ship is the only way back off the
    ///   continent.
    ///
    /// Rivers count as land — `Terrain.isLand` includes them — which is what the
    /// manual means by calling them the fast route inland.
    @discardableResult
    public mutating func step(dx: Int, dy: Int, in map: WorldMap) -> Outcome {
        let nx = position.x + dx, ny = position.y + dy
        guard map.contains(x: nx, y: ny) else { return .blocked(.offMap) }
        let target = map[nx, ny]

        switch mode {
        case .aboard:
            position = (nx, ny)
            if target.isWater {
                ship = position
                return .sailed
            }
            // The ship stays on the water it was already on; only the party
            // moves onto the land.
            mode = .ashore
            return .landed

        case .ashore:
            if (nx, ny) == ship {
                mode = .aboard
                position = ship
                return .boarded
            }
            guard target.isLand else { return .blocked(.partyCannotSwim) }
            position = (nx, ny)
            return .walked
        }
    }
}
