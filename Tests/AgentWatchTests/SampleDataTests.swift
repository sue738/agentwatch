import XCTest
@testable import agentwatch

final class SampleDataTests: XCTestCase {
    func testPublicScreenshotUsesCompleteSyntheticSeries() {
        let (report, legacy) = SampleData.make(now: Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(report.daily.count, 60)
        XCTAssertEqual(legacy.days.count, 30)
        XCTAssertEqual(report.rateWindows.count, 2)
        XCTAssertEqual(legacy.rateWindows.count, 2)
    }
}
