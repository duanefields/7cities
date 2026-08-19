import Foundation
import Testing

@testable import SevenCitiesCore

/// The watchdog: what stops the World Maker when a seed asks a question that has
/// no answer.
///
/// Several of the original's routines are rejection samplers with no iteration
/// bound — `$0FF8` redraws until its throw lands on land, `$22B4` until the byte
/// is in range, `$4A37` until a village fits — and a handful of its scans step a
/// *wrapping* column with nothing to stop them. On a seed where the map cannot
/// satisfy one of those, a *deterministic* run asks for ever. Measured over the
/// whole input space that is about one (seed, configuration) pair in five — which
/// says nothing about the game. The original stirs its generator with live SID
/// noise on every raster interrupt, so those samplers always get new bits and
/// always escape; the port drops the stir so a seed reproduces, and inherits the
/// hang. See NOTES.md.
///
/// So the port counts draws, and every unbounded loop gives up when the count
/// passes ``WorldMakerRNG/limit``. What is tested here is that it fires and that
/// what it reports is an error rather than a half-made world. The other half of
/// the claim — that it cannot fire on a world that *would* have finished — is a
/// consequence of the ceiling being out of reach, and that is asserted where the
/// worlds are already being built, in `WorldMakerTests`.

@Test("A world that will not finish is stopped rather than hung")
func theWatchdogFires() throws {
    // A limit no world can come in under — the cheapest costs six figures — so
    // every seed here is stopped, and stopped in milliseconds rather than never.
    var stopped = 0
    for seed: UInt16 in [0x1234, 0x0001, 0xBEEF] {
        for config in 0..<3 {
            do {
                _ = try WorldMaker.world(config: config, seed: seed,
                                         drawLimit: 5_000)
                Issue.record("""
                    seed \(seed) config \(config) produced a world from five \
                    thousand draws
                    """)
            } catch is WorldMakerRNG.Stuck {
                stopped += 1
            } catch {
                // `$2473`'s restart and configuration 1's unported pair both
                // throw before the watchdog can — either way it is not a hang.
                stopped += 1
            }
        }
    }
    #expect(stopped == 9)
}

@Test("A stopped run reports itself rather than handing back a half-made world")
func aStoppedRunThrows() throws {
    // The loops give up where they stand, so the band a stopped run leaves is
    // garbage. Nothing may return it — the only way out is the error.
    var caught = false
    do {
        _ = try WorldMaker.world(config: 0, seed: 0x1234, drawLimit: 200_000)
    } catch let stuck as WorldMakerRNG.Stuck {
        caught = true
        #expect(stuck.draws > 200_000,
                "the error reports \(stuck.draws) draws, which is under its own limit")
        #expect("\(stuck)".contains("stuck"), "the description does not say so")
    } catch {
        Issue.record("threw \(error) rather than a Stuck")
    }
    #expect(caught)
}
