/// `$3961`, the rivers that run out of the lakes.
///
/// The second of the three entries into the water engine. For each satellite —
/// the lakes the land-mass phase placed — it finds the ring of `$0F` marks
/// `$2D23` laid around it, works out which way the land runs furthest, and
/// sends a river out that way.
///
/// It is the same walker as `$380D`'s with three rules changed, and the changes
/// are all about running into water that is already there: a river crossing
/// another does not unwind, it writes a `$4` and joins; the fan of directions is
/// **scored** rather than taken first-come; and the lake test is skipped while
/// the walk is still within ten cells of where it started, because the source is
/// against a lake and the test would refuse every step.
extension TerrainPhases {

    /// `$3961`: every lake's outflow, in the order the tables hold them.
    public static func lakeOutflows(_ satellites: [LandMassStage.Island],
                                    in band: inout TerrainBand,
                                    rng: inout WorldMakerRNG,
                                    engine: inout RiverEngine,
                                    secondBand: Bool) {
        for satellite in satellites where satellite.southern == secondBand {
            let row = secondBand ? Int(satellite.row) - 192 : Int(satellite.row)
            guard row >= 0 && row < TerrainBand.rows else { continue }
            // $3999: a marsh around the lake itself, before anything flows out
            // of it. Radius seven, which is the largest the World Maker uses.
            swamp(radius: 7, at: satellite.column, row, in: &band, rng: &rng,
                  secondBand: secondBand)
            guard let mark = findMark(around: satellite.column, row, in: band)
            else { continue }
            outflow(from: mark, in: &band, rng: &rng, engine: &engine,
                    secondBand: secondBand)
        }
        upstream(in: &band, rng: &rng, engine: &engine, secondBand: secondBand)
    }

    /// `$3B75`: grow a river inland from every mouth that has room.
    ///
    /// Once every lake has run, the phase walks the mouth table `$3531` filled
    /// and tries to push each one further into the land. A mouth with two or
    /// more river neighbours east and west is measured north and south instead,
    /// and the other way round; whichever run of unbroken land is longer wins,
    /// and it has to be at least twenty-five cells. Then a river runs that way
    /// until it has come far enough — ten cells at least, forty-five at most,
    /// and never further than the mouth's own river was long.
    private static func upstream(in band: inout TerrainBand,
                                 rng: inout WorldMakerRNG,
                                 engine: inout RiverEngine, secondBand: Bool) {
        // $3B75: `$56` counts bytes, three to a mouth.
        for mouth in engine.mouths {
            let row = Int(mouth.row)
            // $3BA4: the neighbours either side.
            var beside = 0
            for dx in [-1, 1] {
                let nibble = band[mouth.column &+ UInt8(bitPattern: Int8(dx)), row]
                if nibble >= 0x04 && nibble < 0x0B { beside += 1 }
            }

            let heading: UInt8
            if beside >= 2 {
                // $3BD1: north and south.
                let north = landRun(from: mouth.column, row, dy: -1, in: band)
                let south = landRun(from: mouth.column, row, dy: 1, in: band)
                guard south >= 0x19 || north >= 0x19 else { continue }
                if south == north {
                    heading = Int8(bitPattern: rng.next()) < 0 ? 0 : 3
                } else {
                    heading = south > north ? 0 : 3               // $3C36
                }
            } else {
                // $3C56: west and east.
                let west = landRun(from: mouth.column, row, dx: -1, in: band)
                let east = landRun(from: mouth.column, row, dx: 1, in: band)
                guard east >= 0x19 || west >= 0x19 else { continue }
                if east == west {
                    heading = Int8(bitPattern: rng.next()) < 0 ? 2 : 1
                } else {
                    heading = east > west ? 2 : 1                 // $3CB7
                }
            }

            // $3CD5: a third setup, whose exits are "next mouth" and "carry on".
            engine.start(heading: heading, persistence: 0xB4)
            engine.column = mouth.column
            engine.row = row
            engine.run(3, in: &band, rng: &rng)                   // $3CE6
            inland(&engine, from: mouth, in: &band, rng: &rng,
                   secondBand: secondBand)
        }
    }

    /// `$3BDD` and its three siblings: how far unbroken land runs one way, to a
    /// ceiling of twenty-six.
    private static func landRun(from column: UInt8, _ row: Int,
                                dx: Int = 0, dy: Int = 0,
                                in band: TerrainBand) -> UInt8 {
        var x = column, y = row, run: UInt8 = 0
        // $3BD5 and $3C5A refuse to start within two of the edge at all.
        if dy < 0 && row < 2 { return 0 }
        if dx < 0 && column < 2 { return 0 }
        if dy > 0 && row >= 0xCC { return 0 }
        if dx > 0 && column >= 0xFD { return 0 }
        while run < 0x1A {
            x = x &+ UInt8(bitPattern: Int8(dx))
            y += dy
            let nibble = band[x, y]
            if nibble == 0x0F || nibble < 0x0B { return run }
            if dy < 0 && y == 0 { return run }
            if dx < 0 && x == 0 { return run }
            if dy > 0 && y >= 0xCE { return run }
            run &+= 1
        }
        return run
    }

    /// `$3CEB`: the upstream walk, which only grows through solid land.
    ///
    /// Its fan is six cells deep in all three directions and every one of them
    /// has to be land — anything else and the river unwinds. That is why these
    /// are short: seven of them in the first band and none longer than ten
    /// cells.
    private static func inland(_ engine: inout RiverEngine,
                               from mouth: RiverEngine.Mouth,
                               in band: inout TerrainBand,
                               rng: inout WorldMakerRNG, secondBand: Bool) {
        while true {
            engine.stopIndex = engine.index &+ 1                  // $3CEB
            engine.choose(rng: &rng)
            engine.aim(rng: &rng)

            var give = secondBand ? engine.nextRow == 1 : engine.nextRow >= 0xCE
            if !give {
                let nibble = band[engine.nextColumn, engine.nextRow]
                if nibble == 0x0F || nibble < 0x0B { give = true } // $3D05
            }
            if !give {
                fan: for probe in 0..<3 {
                    let direction = RiverEngine.lookahead[Int(engine.last) * 4 + probe]
                    guard direction != 0xFF else { continue }
                    let step = RiverEngine.steps[Int(direction) / 2]
                    var x = engine.nextColumn
                    var y = engine.nextRow
                    for _ in 0..<6 {                              // $3D1F
                        x = x &+ UInt8(bitPattern: step.dx)
                        if x == 0 { continue fan }
                        y += Int(step.dy)
                        if secondBand ? y < 1 : y >= 0xCE { continue fan }
                        let nibble = band[x, y]
                        if nibble == 0x0F || nibble < 0x0B { give = true; break fan }
                    }
                }
            }

            if give {
                if engine.erase(allowance: 0x06, stop: engine.stopIndex,
                                in: &band, rng: &rng) == .exhausted { return }
                continue
            }

            engine.take(in: &band)                                // $3D4D
            // $3D50: far enough to stop looking, or too far to go on.
            let far = engine.length
            if far < 0x0A { continue }
            if far >= 0x2D { break }
            if far >= mouth.length { break }
            if rng.next() >= 0x0A { continue }
            break
        }
        // $3D68: the river is filed the other way round from the rest — the
        // *source* is where this walk ended, upstream, and its other end is the
        // mouth it grew out of.
        let source = (column: engine.column, row: engine.row)
        engine.column = mouth.column
        engine.row = Int(mouth.row)
        engine.fileSource(from: source.column, source.row, secondBand: secondBand)
    }

    /// `$39AB`: hunt outward from the lake for the ring of marks.
    ///
    /// West along the row, then east, then a row up and the same again — until
    /// a `$0F` turns up or the box runs out. The box is `$2A45`'s at radius 10
    /// and this one *is* closed on all four sides, unlike the two the rivers
    /// test against.
    private static func findMark(around column: UInt8, _ row: Int,
                                 in band: TerrainBand) -> (UInt8, Int)? {
        let area = box(around: column, UInt8(truncatingIfNeeded: row), radius: 10)
        var y = row
        while true {
            var x = column
            while true {                                      // $39AB, west
                if band[x, y] == 0x0F { return (x, y) }
                if x == 0 { break }
                x &-= 1
                if x < area.left { break }
            }
            x = column
            while true {                                      // $39C4, east
                if band[x, y] == 0x0F { return (x, y) }
                x &+= 1
                if x >= area.right { break }
            }
            if y == 0 { return nil }
            y -= 1                                            // $39DB
            if y < Int(area.top) { return nil }
        }
    }

    /// `$39EF` onward: one lake's river, from the mark to wherever it ends.
    private static func outflow(from mark: (column: UInt8, row: Int),
                                in band: inout TerrainBand,
                                rng: inout WorldMakerRNG,
                                engine: inout RiverEngine, secondBand: Bool) {
        // $4014: how far the land runs each way, and $39F2 takes the shortest
        // run of at least seventeen. $40BF leaves both the best distance and the
        // best index at $FF, so finding nothing leaves $53 negative and the walk
        // heads west by default.
        let runs = landRuns(from: mark, in: band, secondBand: secondBand)
        var best: UInt8 = 0xFF
        var heading: UInt8 = 0xFF
        for index in stride(from: 3, through: 0, by: -1) {    // $3A01 DEX/BPL
            let run = runs[index]
            if run < 0x11 { continue }                        // $39F5
            if run >= best { continue }                       // $39F9
            best = run
            heading = UInt8(index)
        }

        engine.start(heading: heading & 3, persistence: 0xB4)
        engine.column = mark.column
        engine.row = mark.row

        // $3A14: out of the lake's marked water, then one step back onto its
        // edge. Which way depends on the index, and $FF falls to the west case.
        switch heading {
        case 0: while band[engine.column, engine.row] == 0x0F { engine.row += 1 }
                engine.row -= 1
        case 2: while band[engine.column, engine.row] == 0x0F { engine.column &+= 1 }
                engine.column &-= 1
        case 3: while band[engine.column, engine.row] == 0x0F { engine.row -= 1 }
                engine.row += 1
        default: while band[engine.column, engine.row] == 0x0F { engine.column &-= 1 }
                 engine.column &+= 1
        }
        // The $3A22 family step *first* and test after, so the loop above is one
        // short; $3A33 and its siblings put that step back.
        let anchor = (row: engine.row, column: engine.column)  // $3A73 into $2C/$2D

        engine.run(1, in: &band, rng: &rng)                   // $4006
        engine.sourceColumn = engine.column
        engine.sourceRow = engine.row
        engine.run(5, in: &band, rng: &rng)                   // $3A7E

        walk(&engine, anchor: anchor, in: &band, rng: &rng, secondBand: secondBand)
    }

    /// `$4014`: how far the land runs west, east, north and south of a point.
    ///
    /// Indexed the way the original's `$0200` page is — south, west, east,
    /// north — and `$FF` where the run reaches nibble `$3`, the island mark,
    /// before it reaches water.
    private static func landRuns(from mark: (column: UInt8, row: Int),
                                 in band: TerrainBand,
                                 secondBand: Bool) -> [UInt8] {
        func run(_ dx: Int, _ dy: Int, limit: (UInt8) -> Bool) -> UInt8 {
            var distance: UInt8 = 0
            var x = mark.column
            var y = mark.row
            while true {
                let nibble = band[x, y]
                if nibble == 0x03 { return 0xFF }             // $4024 CMP $BB
                if nibble < 0x0B { return distance }
                distance &+= 1
                x = x &+ UInt8(bitPattern: Int8(dx))
                y += dy
                if limit(UInt8(truncatingIfNeeded: y)) { return 0xFF }
            }
        }
        // $4021 and $4045 have no bound at all beyond the wrap; the vertical
        // pair stop at row 2 or $11 going up and row $CD going down.
        let west = run(-1, 0) { _ in false }
        let east = run(1, 0) { _ in false }
        let north = run(0, -1) { row in row == (secondBand ? 0x11 : 0x02) }
        let south = run(0, 1) { row in row >= 0xCD }
        return [south, west, east, north]
    }

    /// `$3A83`: the lake river's walk.
    private static func walk(_ engine: inout RiverEngine,
                             anchor: (row: Int, column: UInt8),
                             in band: inout TerrainBand,
                             rng: inout WorldMakerRNG, secondBand: Bool) {
        while true {
            let stop = engine.index &+ 1                      // $3A83
            engine.stopIndex = stop
            engine.choose(rng: &rng)                          // $3A88
            engine.aim(rng: &rng)

            let offEdge = secondBand ? engine.nextRow == 1 : engine.nextRow >= 0xCE
            var give = offEdge
            var join = false

            if !give {
                let nibble = band[engine.nextColumn, engine.nextRow]
                if nibble < 3 { finish(&engine, in: &band, rng: &rng,
                                       secondBand: secondBand); return }
                if nibble == 0x0F || nibble == 0x04 {
                    give = true                               // $3AB4
                } else if nibble < 0x0B {
                    // $3AC0: a river already here. Joining it is allowed unless
                    // the record says the walk has been here before.
                    if inRecord(engine, at: engine.nextColumn, engine.nextRow,
                                in: band) {
                        give = true
                    } else {
                        join = true
                    }
                }
            }

            if !give && !join {
                switch fan(&engine, in: band, secondBand: secondBand) {
                case .none: give = true
                case .unwind: give = true
                case .sea:
                    carry(&engine, until: 0x03, in: &band, rng: &rng)
                    finish(&engine, in: &band, rng: &rng, secondBand: secondBand)
                    return                                    // $3B5E
                case .river:
                    carry(&engine, until: 0x0B, in: &band, rng: &rng)
                    join = true                               // $3B66
                case .step: break
                }
            }

            if join {
                engine.tile = 0x04                            // $3AC5
                engine.take(in: &band)
                finish(&engine, in: &band, rng: &rng, secondBand: secondBand)
                return
            }

            if !give {
                // $3B2F: near the source the lake test is skipped, because the
                // source is *against* a lake and the test would refuse every
                // step out of it.
                let dy = abs(anchor.row - engine.nextRow)
                let dx = abs(Int(anchor.column) - Int(engine.nextColumn))
                if dy >= 10 || dx >= 10 {
                    if !engine.clearOfLakes(in: band) { give = true }
                }
            }

            if give {
                if engine.erase(allowance: 0x06, stop: stop, in: &band,
                                rng: &rng) == .exhausted {
                    return
                }
                continue
            }

            engine.take(in: &band)                            // $3B55
            _ = engine.fileMouth(in: &band, sourcesFull: false)
        }
    }

    private enum Fan { case none, unwind, sea, river, step }

    /// `$3ACF`: the same three-direction, seven-deep fan `$380D` uses, but
    /// **scored** — `$37DD` and `$37E8` keep the shortest reach found rather
    /// than committing to the first, and `$37FF` takes that one at the end.
    private static func fan(_ engine: inout RiverEngine, in band: TerrainBand,
                            secondBand: Bool) -> Fan {
        var bestReach: UInt8 = 0xFF
        var bestDirection: UInt8 = 0
        var bestIsRiver = false

        for probe in 0..<3 {
            let direction = RiverEngine.lookahead[Int(engine.last) * 4 + probe]
            guard direction != 0xFF else { continue }
            let step = RiverEngine.steps[Int(direction) / 2]
            var x = engine.nextColumn
            var y = engine.nextRow
            var reach: UInt8 = 0
            while reach < 7 {
                x = x &+ UInt8(bitPattern: step.dx)
                if x == 0 { break }                           // $3AEC
                y += Int(step.dy)
                if secondBand ? y < 1 : y >= 0xCE { break }
                let nibble = band[x, y]
                if nibble == 0x04 { return .unwind }          // $3B03
                if nibble < 0x04 {                            // $3B07
                    if reach < bestReach {
                        bestReach = reach; bestDirection = direction
                        bestIsRiver = false
                    }
                    break
                }
                if nibble < 0x0B {                            // $3B10
                    if inRecord(engine, at: x, y, in: band) { return .unwind }
                    if reach < bestReach {
                        bestReach = reach; bestDirection = direction
                        bestIsRiver = true
                    }
                    break
                }
                reach &+= 1
            }
        }
        guard bestReach != 0xFF else { return .step }         // $3B28 BMI
        engine.chosen = bestDirection / 2
        return bestIsRiver ? .river : .sea                    // $37FF
    }

    /// `$369F` again, with the threshold the caller wants.
    private static func carry(_ engine: inout RiverEngine, until threshold: UInt8,
                              in band: inout TerrainBand,
                              rng: inout WorldMakerRNG) {
        let heading = engine.chosen
        engine.tile = RiverEngine.tiles[Int(heading) * 4 + Int(engine.last)] ?? 0
        while true {
            engine.take(in: &band)
            engine.chosen = heading
            engine.aim(rng: &rng)
            if band[engine.nextColumn, engine.nextRow] < threshold { return }
        }
    }

    /// `$364C` into `$36CC`, then the distant swamp unless the river ended on a
    /// shallow.
    private static func finish(_ engine: inout RiverEngine,
                               in band: inout TerrainBand,
                               rng: inout WorldMakerRNG, secondBand: Bool) {
        engine.fileSource(from: engine.sourceColumn, engine.sourceRow,
                          secondBand: secondBand)
        if engine.tile != 0x04 {                              // $3AAA
            distantSwamp(&engine, in: &band, rng: &rng, secondBand: secondBand)
        }
    }

    /// `$348D`: has the walk already been through this cell, or is it hemmed in?
    ///
    /// Carry set — refuse — when the position is in the record, when a neighbour
    /// is a `$4`, or when fewer than two neighbours are river.
    private static func inRecord(_ engine: RiverEngine, at column: UInt8,
                                 _ row: Int, in band: TerrainBand) -> Bool {
        var probe = engine.index
        while true {
            let step = engine.step(at: probe)
            if step.row == UInt8(truncatingIfNeeded: row) && step.column == column {
                return true                                   // $34F1
            }
            if engine.wrapped != 0 && probe == 0 { break }
            if probe == engine.stopIndex { break }            // $34DF
            probe = probe == 0 ? 0xFA : probe &- 1
        }
        // $34AE: the neighbours. A `$4` among them is an immediate refusal
        // through $37D9's PLA/PLA.
        var rivers = 0
        for (dx, dy) in [(0, -1), (0, 1), (-1, 0), (1, 0)] {
            if dy == -1 && row == 0 { continue }
            if dy == 1 && row >= 0xCE { continue }
            let nibble = band[column &+ UInt8(bitPattern: Int8(dx)), row + dy]
            if nibble == 0x04 { return true }                 // $37D9
            if nibble > 0x04 && nibble < 0x0B { rivers += 1 }
        }
        return rivers >= 2                                    // $34D9
    }
}
