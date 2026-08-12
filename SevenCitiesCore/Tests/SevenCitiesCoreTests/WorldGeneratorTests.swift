import Testing

@testable import SevenCitiesCore

@Test("A generated world is deterministic for a given seed")
func generationIsDeterministic() {
    var a = WorldGenerator(seed: 4242)
    var b = WorldGenerator(seed: 4242)
    let x = a.generate(), y = b.generate()
    #expect(x.width == y.width && x.height == y.height)
    for i in stride(from: 0, to: x.width * x.height, by: 97) {
        let px = (i % x.width, i / x.width)
        #expect(x[px.0, px.1] == y[px.0, px.1])
    }
}

@Test("Different seeds give different worlds")
func seedsDiffer() {
    var a = WorldGenerator(seed: 1)
    var b = WorldGenerator(seed: 2)
    let x = a.generate(), y = b.generate()
    var same = 0, total = 0
    for i in stride(from: 0, to: x.width * x.height, by: 31) {
        let p = (i % x.width, i / x.width)
        if x[p.0, p.1] == y[p.0, p.1] { same += 1 }
        total += 1
    }
    #expect(Double(same) / Double(total) < 0.95, "worlds are suspiciously alike")
}

@Test("A generated world has a plausible mix of terrain")
func generationIsPlausible() {
    var gen = WorldGenerator(seed: 777)
    let map = gen.generate()
    var counts: [Terrain: Int] = [:]
    for y in 0..<map.height {
        for x in 0..<map.width { counts[map[x, y], default: 0] += 1 }
    }
    let total = map.width * map.height
    let water = Terrain.allCases.filter(\.isWater).reduce(0) { $0 + (counts[$1] ?? 0) }
    let land = total - water

    #expect(water > total / 5, "a world should be mostly ocean")
    #expect(land > total / 20, "a world needs meaningful land")
    #expect((counts[.mediumWater] ?? 0) + (counts[.shallowWater] ?? 0) > 0,
            "land should be ringed by a shelf")
    #expect((counts[.mountain] ?? 0) > 0)
    #expect((counts[.forest] ?? 0) > 0)
    #expect((counts[.village] ?? 0) > 0)
    let rivers = Terrain.allCases.filter(\.isRiver).reduce(0) { $0 + (counts[$1] ?? 0) }
    #expect(rivers > 0, "a world should have rivers")
}

@Test("Generated river tiles only ever use valid connection masks")
func riverTilesAreWellFormed() {
    var gen = WorldGenerator(seed: 31337)
    let map = gen.generate()
    for y in 0..<map.height {
        for x in 0..<map.width {
            let t = map[x, y]
            guard t.isRiver else { continue }
            #expect(t.riverConnections.count >= 2)
        }
    }
}
