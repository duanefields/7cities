import Foundation
import Testing

@testable import SevenCitiesCore

private func makeMap(_ w: Int, _ h: Int, _ fill: Terrain = .deepWater) -> Data {
    var d = Data([0x37, 0x43, 0x4D, 0x50, 1])
    d.append(UInt8(w & 0xFF)); d.append(UInt8(w >> 8))
    d.append(UInt8(h & 0xFF)); d.append(UInt8(h >> 8))
    d.append(contentsOf: [UInt8](repeating: fill.rawValue, count: w * h))
    return d
}

@Test("Loads a well-formed map file")
func loadsValidMap() throws {
    let map = try WorldMap(data: makeMap(8, 4, .plain))
    #expect(map.width == 8)
    #expect(map.height == 4)
    #expect(map[0, 0] == .plain)
    #expect(map[7, 3] == .plain)
}

@Test("Rejects malformed map files")
func rejectsBadFiles() {
    #expect(throws: WorldMap.LoadError.self) { try WorldMap(data: Data([1, 2, 3])) }
    var badMagic = makeMap(2, 2)
    badMagic[0] = 0x00
    #expect(throws: WorldMap.LoadError.self) { try WorldMap(data: badMagic) }
    var badVersion = makeMap(2, 2)
    badVersion[4] = 99
    #expect(throws: WorldMap.LoadError.self) { try WorldMap(data: badVersion) }
    var truncated = makeMap(4, 4)
    truncated.removeLast(3)
    #expect(throws: WorldMap.LoadError.self) { try WorldMap(data: truncated) }
}

@Test("Off-map reads are deep water rather than a crash")
func offMapIsOcean() throws {
    let map = try WorldMap(data: makeMap(4, 4, .plain))
    #expect(map[-1, 0] == .deepWater)
    #expect(map[0, -1] == .deepWater)
    #expect(map[4, 0] == .deepWater)
    #expect(map[0, 4] == .deepWater)
    #expect(!map.contains(x: 4, y: 4))
}

@Test("River tiles connect in exactly the six two-way combinations")
func riverConnectionsAreComplete() {
    let twoWay: [Terrain] = [.riverWE, .riverNS, .riverNW, .riverSW, .riverNE, .riverSE]
    for t in twoWay {
        #expect(t.riverConnections.count == 2, "\(t) should link two directions")
    }
    // every distinct pair of directions is covered exactly once
    let sets = Set(twoWay.map { $0.riverConnections })
    #expect(sets.count == 6)
    #expect(Terrain.riverJunction.riverConnections.count == 4)
    #expect(Terrain.plain.riverConnections.isEmpty)
}

@Test("Terrain classification matches the original's vocabulary")
func classification() {
    #expect(Terrain.deepWater.isWater)
    #expect(Terrain.mediumWater.isWater)
    #expect(Terrain.shallowWater.isWater)
    #expect(!Terrain.plain.isWater)
    #expect(Terrain.riverNS.isRiver)
    #expect(Terrain.riverJunction.isRiver)
    #expect(!Terrain.swamp.isRiver)
    #expect(Terrain.riverNS.displayName == "RIVER")
    #expect(Terrain.riverJunction.displayName == "RIVER")
    #expect(Terrain.swamp.displayName == "SWAMP")
    #expect(Terrain.allCases.count == 16)
}

@Test("Suggested start is on land, next to water when possible")
func suggestedStart() throws {
    var d = makeMap(8, 8, .deepWater)
    // one land tile in the middle band
    let idx = 9 + (4 * 8 + 3)
    d[idx] = Terrain.plain.rawValue
    let map = try WorldMap(data: d)
    let start = try #require(map.suggestedStart())
    #expect(map[start.x, start.y].isLand)
}
