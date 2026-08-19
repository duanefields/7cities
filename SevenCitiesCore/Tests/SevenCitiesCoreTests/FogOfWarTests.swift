import Testing

@testable import SevenCitiesCore

@Test("A fresh fog hides everything")
func fogStartsBlank() {
    let fog = FogOfWar(width: 20, height: 20)
    #expect(fog.exploredCount == 0)
    #expect(fog.visibility(x: 10, y: 10) == .unseen)
}

@Test("Looking once uncovers exactly the original's aperture")
func apertureIsSevenSquare() {
    var fog = FogOfWar(width: 40, height: 40)
    let uncovered = fog.look(from: (x: 20, y: 20))
    // Chebyshev radius 3 is the 7x7 block centered on the eye — the original's
    // 6x6 window, as a radius. See `FogOfWar`.
    #expect(uncovered == 49)
    #expect(fog.exploredCount == 49)
    #expect(fog.visibility(x: 23, y: 23) == .visible)     // the far corner
    #expect(fog.visibility(x: 24, y: 20) == .unseen)      // one step beyond
}

@Test("Sailing a straight line leaves a swath exactly seven tiles wide")
func straightLineSwath() {
    var fog = FogOfWar(width: 60, height: 40)
    let row = 20
    for x in 10...40 { fog.look(from: (x: x, y: row)) }

    // Every column the track passed through, well clear of the ends, is
    // explored for exactly seven rows and no more.
    for x in 14...36 {
        let explored = (0..<40).filter { fog.isExplored(x: x, y: $0) }
        #expect(explored == Array((row - 3)...(row + 3)),
                "column \(x) should be explored for rows \(row - 3)...\(row + 3)")
    }
}

@Test("Terrain left behind is remembered, not forgotten and not still in sight")
func memoryOutlastsSight() {
    var fog = FogOfWar(width: 60, height: 20)
    fog.look(from: (x: 10, y: 10))
    #expect(fog.visibility(x: 10, y: 10) == .visible)

    fog.look(from: (x: 30, y: 10))
    #expect(fog.visibility(x: 10, y: 10) == .remembered)
    #expect(fog.visibility(x: 30, y: 10) == .visible)
    #expect(fog.visibility(x: 20, y: 10) == .unseen)   // the gap between them
}

@Test("Retracing your own path uncovers nothing new")
func retracingIsFree() {
    var fog = FogOfWar(width: 40, height: 40)
    for x in 10...20 { fog.look(from: (x: x, y: 20)) }
    let after = fog.exploredCount
    for x in stride(from: 20, through: 10, by: -1) {
        #expect(fog.look(from: (x: x, y: 20)) == 0)
    }
    #expect(fog.exploredCount == after)
}

@Test("Looking from a corner clips to the map rather than trapping")
func edgesClip() {
    var fog = FogOfWar(width: 30, height: 30)
    let uncovered = fog.look(from: (x: 0, y: 0))
    #expect(uncovered == 16)                              // a quarter of 7x7
    #expect(fog.visibility(x: 3, y: 3) == .visible)
    #expect(fog.visibility(x: 4, y: 0) == .unseen)
}

@Test("The explored fraction is the discovery screen's numerator")
func exploredFraction() {
    var fog = FogOfWar(width: 100, height: 100)
    fog.look(from: (x: 50, y: 50))
    #expect(abs(fog.exploredFraction - 49.0 / 10_000.0) < 1e-12)
}
