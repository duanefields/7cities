import Foundation
import Testing

@testable import SevenCitiesCore

/// A strip of ocean with a continent on the left: columns 0-3 are plain, 4-9 are
/// deep water. So sailing west from column 9 reaches the coast at column 4.
private func coastMap(width: Int = 10, height: Int = 5) -> WorldMap {
    var tiles = [Terrain]()
    for _ in 0..<height {
        for x in 0..<width { tiles.append(x < 4 ? .plain : .deepWater) }
    }
    return WorldMap(width: width, height: height, tiles: tiles)
}

@Test("An expedition begins at sea, aboard, with the ship under it")
func startsAboard() {
    let e = Expedition(atSea: (x: 8, y: 2))
    #expect(e.mode == .aboard)
    #expect(!e.isAshore)
    #expect(e.position == (8, 2))
    #expect(e.ship == (8, 2))
}

@Test("Sailing carries the ship along")
func sailingMovesTheShip() {
    var e = Expedition(atSea: (x: 8, y: 2))
    #expect(e.step(dx: -1, dy: 0, in: coastMap()) == .sailed)
    #expect(e.position == (7, 2))
    #expect(e.ship == (7, 2), "the ship is the expedition while aboard")
}

@Test("Stepping at land is the landing, and the ship stays behind")
func steppingAtLandLands() {
    var e = Expedition(atSea: (x: 4, y: 2))
    #expect(e.step(dx: -1, dy: 0, in: coastMap()) == .landed)
    #expect(e.isAshore)
    #expect(e.position == (3, 2), "the party is ashore")
    #expect(e.ship == (4, 2), "the ship moored where it was floating")
}

@Test("A party ashore walks on land and cannot swim")
func partyWalksOnLand() {
    let map = coastMap()
    var e = Expedition(atSea: (x: 4, y: 2))
    e.step(dx: -1, dy: 0, in: map)          // ashore at (3,2), ship at (4,2)

    #expect(e.step(dx: -1, dy: 0, in: map) == .walked)
    #expect(e.position == (2, 2))
    // Water that is not the ship's tile is refused, and nothing moves.
    #expect(e.step(dx: 0, dy: 1, in: map) == .walked)     // still land
    #expect(e.position == (2, 3))
    var stranded = Expedition(atSea: (x: 4, y: 0))
    stranded.step(dx: -1, dy: 0, in: map)                 // ashore at (3,0)
    #expect(stranded.step(dx: 1, dy: 1, in: map) == .blocked(.partyCannotSwim))
    #expect(stranded.position == (3, 0), "a refused step moves nothing")
}

@Test("Walking back onto the ship's own tile re-boards it")
func steppingOntoTheShipBoards() {
    let map = coastMap()
    var e = Expedition(atSea: (x: 4, y: 2))
    e.step(dx: -1, dy: 0, in: map)          // ashore at (3,2), ship at (4,2)
    #expect(e.step(dx: 1, dy: 0, in: map) == .boarded)
    #expect(e.mode == .aboard)
    #expect(e.position == (4, 2))
    #expect(e.ship == (4, 2))
}

@Test("The ship is the only way back off the continent")
func onlyTheShipGetsYouOff() {
    let map = coastMap()
    var e = Expedition(atSea: (x: 4, y: 0))
    e.step(dx: -1, dy: 0, in: map)          // ashore at (3,0), ship at (4,0)
    // (4,1) is water but is not where the ship is, so it is refused even though
    // it sits right beside the party.
    #expect(e.step(dx: 1, dy: 1, in: map) == .blocked(.partyCannotSwim))
    #expect(e.isAshore)
    // The ship's own tile, though, works.
    #expect(e.step(dx: 1, dy: 0, in: map) == .boarded)
}

@Test("A round trip leaves the expedition where it started")
func roundTrip() {
    let map = coastMap()
    var e = Expedition(atSea: (x: 6, y: 2))
    for _ in 0..<2 { e.step(dx: -1, dy: 0, in: map) }     // sail to (4,2)
    #expect(e.step(dx: -1, dy: 0, in: map) == .landed)    // ashore at (3,2)
    for _ in 0..<2 { e.step(dx: -1, dy: 0, in: map) }     // walk inland
    #expect(e.position == (1, 2))
    for _ in 0..<2 { e.step(dx: 1, dy: 0, in: map) }      // walk back
    #expect(e.step(dx: 1, dy: 0, in: map) == .boarded)
    #expect(e.mode == .aboard)
    #expect(e.position == (4, 2))
}

@Test("Steps off the edge of the world are refused, aboard or ashore")
func edgesAreRefused() {
    let map = coastMap()
    var atSea = Expedition(atSea: (x: 9, y: 2))
    #expect(atSea.step(dx: 1, dy: 0, in: map) == .blocked(.offMap))
    #expect(atSea.position == (9, 2))

    var ashore = Expedition(atSea: (x: 4, y: 0))
    ashore.step(dx: -1, dy: 0, in: map)
    #expect(ashore.step(dx: 0, dy: -1, in: map) == .blocked(.offMap))
}

@Test("Rivers are land, because they are the route inland")
func riversAreWalkable() {
    var tiles = [Terrain](repeating: .deepWater, count: 9)
    tiles[3] = .riverWE        // (0,1)
    tiles[4] = .plain          // (1,1)
    let map = WorldMap(width: 3, height: 3, tiles: tiles)

    var e = Expedition(atSea: (x: 2, y: 1))
    #expect(e.step(dx: -1, dy: 0, in: map) == .landed)   // onto plain at (1,1)
    #expect(e.step(dx: -1, dy: 0, in: map) == .walked)   // onto the river at (0,1)
    #expect(e.position == (0, 1))
}
