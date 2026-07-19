import XCTest
@testable import AgentSession

final class ClaudeQuotaTests: XCTestCase {

    /// The real /api/oauth/usage shape (from community reverse-engineering).
    private let sample = """
    {
      "five_hour": { "utilization": 33.0, "resets_at": "2026-04-11T07:00:00.528743+00:00" },
      "seven_day": { "utilization": 13.0, "resets_at": "2026-04-17T00:59:59.951713+00:00" },
      "seven_day_opus": null,
      "seven_day_sonnet": { "utilization": 1.0, "resets_at": "2026-04-16T03:00:00.951719+00:00" },
      "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
    }
    """

    func testParsesRealShape() throws {
        let q = try XCTUnwrap(ClaudeQuota.parse(sample))
        XCTAssertEqual(q.fiveHour?.utilization, 33.0)
        XCTAssertEqual(q.fiveHour?.percentUsed, 33)
        XCTAssertEqual(q.fiveHour?.percentRemaining, 67)
        XCTAssertEqual(q.sevenDay?.percentUsed, 13)
        XCTAssertNil(q.sevenDayOpus)                 // null window dropped
        XCTAssertEqual(q.sevenDaySonnet?.percentUsed, 1)
        XCTAssertNotNil(q.fiveHour?.resetsAt)        // microsecond fraction parsed
    }

    func testMicrosecondResetDateParses() throws {
        let d = try XCTUnwrap(ClaudeQuota.parseDate("2026-04-11T07:00:00.528743+00:00"))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-04-11T07:00:00Z"))
        XCTAssertEqual(d.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testPlainSecondResetDateParses() throws {
        XCTAssertNotNil(ClaudeQuota.parseDate("2026-04-11T07:00:00Z"))
        XCTAssertNotNil(ClaudeQuota.parseDate("2026-04-11T07:00:00+00:00"))
    }

    func testZeroUtilizationIsAValidWindow() throws {
        let q = try XCTUnwrap(ClaudeQuota.parse(#"{"five_hour":{"utilization":0,"resets_at":null}}"#))
        XCTAssertEqual(q.fiveHour?.percentUsed, 0)
        XCTAssertNil(q.fiveHour?.resetsAt)
    }

    func testClampsOutOfRangeUtilization() throws {
        let q = try XCTUnwrap(ClaudeQuota.parse(#"{"seven_day":{"utilization":140}}"#))
        XCTAssertEqual(q.sevenDay?.percentUsed, 100)
        XCTAssertEqual(q.sevenDay?.percentRemaining, 0)
    }

    func testErrorBodiesFailSoft() {
        XCTAssertNil(ClaudeQuota.parse(#"{"error":{"type":"rate_limit_error"}}"#))   // no windows
        XCTAssertNil(ClaudeQuota.parse("<html>429</html>"))                          // not JSON
        XCTAssertNil(ClaudeQuota.parse(""))
        XCTAssertNil(ClaudeQuota.parse("{}"))
    }
}
