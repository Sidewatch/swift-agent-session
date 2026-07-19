import XCTest
@testable import AgentSession

final class UsageStreaksTests: XCTestCase {

    private func day(_ offset: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: Date().addingTimeInterval(TimeInterval(offset * 86400)))
    }

    func testEmptyStreaks() {
        let (c, l) = UsageAggregator.streaks([])
        XCTAssertEqual(c, 0); XCTAssertEqual(l, 0)
    }

    func testLongestStreakAcrossGaps() {
        // A 3-day run, a gap, then a 2-day run → longest 3.
        let days: Set<String> = [day(-10), day(-9), day(-8), day(-5), day(-4)]
        XCTAssertEqual(UsageAggregator.streaks(days).longest, 3)
    }

    func testCurrentStreakEndingToday() {
        let days: Set<String> = [day(-2), day(-1), day(0)]
        XCTAssertEqual(UsageAggregator.streaks(days).current, 3)
    }

    func testCurrentStreakEndingYesterdayStillCounts() {
        let days: Set<String> = [day(-2), day(-1)]
        XCTAssertEqual(UsageAggregator.streaks(days).current, 2)
    }

    func testBrokenCurrentStreakIsZero() {
        // Last active day was 3 days ago → current streak broken.
        let days: Set<String> = [day(-5), day(-4), day(-3)]
        XCTAssertEqual(UsageAggregator.streaks(days).current, 0)
        XCTAssertEqual(UsageAggregator.streaks(days).longest, 3)
    }

    func testSingleDay() {
        XCTAssertEqual(UsageAggregator.streaks([day(0)]).current, 1)
        XCTAssertEqual(UsageAggregator.streaks([day(0)]).longest, 1)
    }
}
