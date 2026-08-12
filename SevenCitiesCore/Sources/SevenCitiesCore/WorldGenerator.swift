/// Generates a world in the original's terrain vocabulary.
///
/// **This is not Ozark Softscape's algorithm.** Their World Maker runs a plate
/// tectonics model and a cultural diffusion model in 18 KB of 6502, and porting
/// it is a separate job. This produces a plausible world in the same 16-value
/// vocabulary so the viewer has something to explore without driving an
/// emulator.
///
/// It is driven by `WorldMakerRNG`, which *is* the original's verified
/// generator, so a given seed always yields the same world.
public struct WorldGenerator {

    public let width: Int
    public let height: Int
    private var rng: WorldMakerRNG

    public init(seed: UInt16, width: Int = 256, height: Int = 400) {
        self.width = width
        self.height = height
        self.rng = WorldMakerRNG(seed: seed == 0 ? 1 : seed)
    }

    private mutating func roll(_ bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Int(rng.next()) * bound / 256
    }

    private mutating func chance(_ percent: Int) -> Bool { roll(100) < percent }

    public mutating func generate() -> WorldMap {
        var grid = [Terrain](repeating: .deepWater, count: width * height)
        func idx(_ x: Int, _ y: Int) -> Int { y * width + x }
        func inside(_ x: Int, _ y: Int) -> Bool {
            x >= 1 && y >= 1 && x < width - 1 && y < height - 1
        }

        // 1. Grow landmasses by Eden growth: repeatedly pick an existing land
        //    cell and add one of its neighbours. Unlike a random walk this
        //    reliably produces compact, connected masses rather than threads.
        var land: [Int] = []
        let continents = 2 + roll(3)
        let target = (width * height) / 4          // aim for roughly a quarter land
        for _ in 0..<continents {
            let sx = width / 5 + roll(width * 3 / 5)
            let sy = height / 6 + roll(height * 2 / 3)
            if inside(sx, sy), grid[idx(sx, sy)] == .deepWater {
                grid[idx(sx, sy)] = .plain
                land.append(idx(sx, sy))
            }
        }
        guard !land.isEmpty else { return WorldMap(width: width, height: height, tiles: grid) }
        while land.count < target {
            let seed = land[roll(land.count)]
            let x = seed % width, y = seed / width
            var nx = x, ny = y
            switch roll(4) {
            case 0: nx += 1
            case 1: nx -= 1
            case 2: ny += 1
            default: ny -= 1
            }
            guard inside(nx, ny), grid[idx(nx, ny)] == .deepWater else { continue }
            grid[idx(nx, ny)] = .plain
            land.append(idx(nx, ny))
        }

        // 2. Smooth away the ragged single-cell fringe growth leaves behind.
        for _ in 0..<2 {
            var next = grid
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    var n = 0
                    for dy in -1...1 {
                        for dx in -1...1 where !(dx == 0 && dy == 0) {
                            if grid[idx(x + dx, y + dy)] != .deepWater { n += 1 }
                        }
                    }
                    if grid[idx(x, y)] == .deepWater, n >= 6 { next[idx(x, y)] = .plain }
                    else if grid[idx(x, y)] != .deepWater, n <= 2 { next[idx(x, y)] = .deepWater }
                }
            }
            grid = next
        }
        land = (0..<(width * height)).filter { grid[$0] == .plain }

        // 3. Continental shelf: water near land shallows out, matching the
        //    original's three depths.
        var shelf = grid
        for y in 0..<height {
            for x in 0..<width where grid[idx(x, y)] == .deepWater {
                var near = false, touching = false
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                        if grid[idx(nx, ny)] == .plain {
                            near = true
                            if abs(dx) <= 1 && abs(dy) <= 1 { touching = true }
                        }
                    }
                }
                if touching { shelf[idx(x, y)] = .shallowWater }
                else if near { shelf[idx(x, y)] = .mediumWater }
            }
        }
        grid = shelf

        // 4. Mountain ridges, drawn as chains so they read as ranges.
        let ridges = 8 + roll(12)
        for _ in 0..<ridges {
            guard !land.isEmpty else { break }
            let seed = land[roll(land.count)]
            var x = seed % width, y = seed / width
            let length = 20 + roll(70)
            let vertical = chance(70)
            for _ in 0..<length {
                if inside(x, y), grid[idx(x, y)] == .plain {
                    grid[idx(x, y)] = .mountain
                }
                if vertical { y += chance(50) ? 1 : -1; x += roll(3) - 1 }
                else { x += chance(50) ? 1 : -1; y += roll(3) - 1 }
                if !inside(x, y) { break }
            }
        }

        // 5. Forest and swamp in clusters; swamp prefers the coast.
        for _ in 0..<(50 + roll(50)) {
            guard !land.isEmpty else { break }
            let seed = land[roll(land.count)]
            let cx = seed % width, cy = seed / width
            let swamp = chance(25)
            let r = 3 + roll(9)
            for dy in -r...r {
                for dx in -r...r where dx * dx + dy * dy <= r * r {
                    let x = cx + dx, y = cy + dy
                    guard inside(x, y), grid[idx(x, y)] == .plain else { continue }
                    if chance(70) { grid[idx(x, y)] = swamp ? .swamp : .forest }
                }
            }
        }

        // 6. Rivers: walk from inland toward the sea, then encode each step as
        //    the connection mask the original uses.
        for _ in 0..<(12 + roll(14)) {
            var path: [(Int, Int)] = []
            guard !land.isEmpty else { break }
            let seed = land[roll(land.count)]
            var x = seed % width, y = seed / width
            let down = chance(50)
            for _ in 0..<200 {
                guard inside(x, y) else { break }
                let here = grid[idx(x, y)]
                path.append((x, y))
                if here == .shallowWater || here == .mediumWater || here == .deepWater { break }
                if chance(65) { y += down ? 1 : -1 } else { x += chance(50) ? 1 : -1 }
            }
            guard path.count > 6 else { continue }
            for (i, p) in path.enumerated() {
                guard inside(p.0, p.1), grid[idx(p.0, p.1)].isLand else { continue }
                var dirs = Set<Direction>()
                if i > 0 { dirs.insert(direction(from: p, to: path[i - 1])) }
                if i < path.count - 1 { dirs.insert(direction(from: p, to: path[i + 1])) }
                if let t = riverTile(for: dirs) { grid[idx(p.0, p.1)] = t }
            }
        }

        // 7. Villages, kept off mountains and away from each other.
        var placed = [(Int, Int)]()
        for _ in 0..<(400 + roll(300)) {
            guard !land.isEmpty else { break }
            let seed = land[roll(land.count)]
            let x = seed % width, y = seed / width
            guard inside(x, y) else { continue }
            let t = grid[idx(x, y)]
            guard t == .plain || t == .forest || t == .swamp else { continue }
            if placed.contains(where: { abs($0.0 - x) < 4 && abs($0.1 - y) < 4 }) { continue }
            grid[idx(x, y)] = .village
            placed.append((x, y))
        }

        return WorldMap(width: width, height: height, tiles: grid)
    }

    private func direction(from a: (Int, Int), to b: (Int, Int)) -> Direction {
        if b.1 < a.1 { return .north }
        if b.1 > a.1 { return .south }
        return b.0 > a.0 ? .east : .west
    }

    private func riverTile(for dirs: Set<Direction>) -> Terrain? {
        switch dirs {
        case [.west, .east]: .riverWE
        case [.north, .south]: .riverNS
        case [.north, .west]: .riverNW
        case [.south, .west]: .riverSW
        case [.north, .east]: .riverNE
        case [.south, .east]: .riverSE
        default: dirs.count >= 3 ? .riverJunction : nil
        }
    }
}
