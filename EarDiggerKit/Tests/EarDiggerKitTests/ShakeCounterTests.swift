@testable import EarDiggerKit
import XCTest

final class ShakeCounterTests: XCTestCase {
    private func shakes(_ counter: inout ShakeCounter, count: Int, from start: Int64, every: Int64, g: Double = 3) -> Int? {
        for i in 0..<count {
            let t = start + Int64(i) * every
            // A few samples per swing, all above the threshold: only the first counts.
            for k in 0..<4 where counter.sample(x: g, y: 0, z: 0, atMs: t + Int64(k) * 10) {
                return i
            }
        }
        return nil
    }

    func testSixHardShakesFire() {
        var c = ShakeCounter()
        XCTAssertEqual(5, shakes(&c, count: 6, from: 10_000, every: 300))
    }

    func testGentleOrFewShakesDoNot() {
        var c = ShakeCounter()
        XCTAssertNil(shakes(&c, count: 10, from: 10_000, every: 300, g: 1.5))
        XCTAssertNil(shakes(&c, count: 5, from: 20_000, every: 300))
    }

    func testShakesSpreadOutDoNotAddUp() {
        var c = ShakeCounter()
        // Six peaks, but a second apart: the three-second window restarts.
        XCTAssertNil(shakes(&c, count: 6, from: 10_000, every: 1000))
    }

    func testCooldownAfterFiring() {
        var c = ShakeCounter()
        XCTAssertEqual(5, shakes(&c, count: 6, from: 10_000, every: 200))
        // Straight away again: within the two-second cooldown.
        XCTAssertNil(shakes(&c, count: 6, from: 11_200, every: 100))
        XCTAssertEqual(5, shakes(&c, count: 6, from: 20_000, every: 200))
    }
}
