import Testing

@testable import SevenCitiesCore

// These deliberately need no disk image. The cipher table is a key, not game
// data, so its invariants can be checked in CI; anything that needs `game`
// itself cannot be tested here because no game data ships with this project.

@Test("The game cipher is a bijection over all 256 byte values")
func cipherIsBijection() {
    #expect(GameCipher.substitution.count == 256)
    #expect(Set(GameCipher.substitution).count == 256)
}

@Test("Decrypting is a pure per-byte substitution")
func decryptIsPerByte() {
    let input: [UInt8] = [0x00, 0x7F, 0x80, 0xFF, 0x42, 0x42]
    let out = GameCipher.decrypt(input)
    #expect(out.count == input.count)
    for (i, b) in input.enumerated() {
        #expect(out[i] == GameCipher.substitution[Int(b)])
    }
    // Same input byte must always give the same output, wherever it appears.
    #expect(out[4] == out[5])
}

@Test("The cipher never maps a byte to itself")
func cipherHasNoFixedPoints() {
    // Every byte changing is what made the on-disk file score zero against a
    // RAM dump, which is how the transform was spotted in the first place.
    for b in 0..<256 {
        #expect(GameCipher.substitution[b] != UInt8(b))
    }
}

@Test("Terrain tile geometry matches the original's 2x2 character layout")
func tileGeometry() {
    // 2x2 characters: 8 multicolor pixels across, 16 rows down, 4 glyphs of 8.
    #expect(TerrainTiles.width == 8)
    #expect(TerrainTiles.height == 16)
    #expect(TerrainTiles.bytesPerTile == 32)
    #expect(TerrainTiles.bytesPerTile == 4 * 8)
    #expect(TerrainTiles.width * TerrainTiles.height / 4 == TerrainTiles.bytesPerTile)
}
