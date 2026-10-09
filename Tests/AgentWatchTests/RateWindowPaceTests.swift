import XCTest
@testable import agentwatch

final class RateWindowPaceTests: XCTestCase {
    func testUsageAheadOfElapsedTimeIsFlagged() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let duration: TimeInterval = 5 * 3600
        let reset = now.addingTimeInterval(duration / 2)
        let ahead = RateWindow(usedPercent: 60, resetsAt: reset, observedAt: now)
        let behind = RateWindow(usedPercent: 40, resetsAt: reset, observedAt: now)

        XCTAssertEqual(RateWindowPace.elapsed(ahead, duration: duration, now: now), 0.5)
        XCTAssertTrue(RateWindowPace.isAhead(ahead, duration: duration, now: now))
        XCTAssertFalse(RateWindowPace.isAhead(behind, duration: duration, now: now))
    }
}
