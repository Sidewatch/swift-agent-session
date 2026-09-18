//
//  ClaudeQuotaTests.swift
//  AgentSessionTests
//
//  The real /api/oauth/usage shape (from community reverse-engineering).
//
//  Created by David Sherlock on 7/19/26.
//

import XCTest
@testable import AgentSession

/// Tests for `ClaudeQuota.parse` against the real `/api/oauth/usage` shape: windows, null
/// windows, reset dates and extra usage.
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

    /// The Sep 2026 shape, captured from a live account (amounts changed): the per-model weekly
    /// cap is a `limits` row scoped to a model, the `seven_day_<model>` keys are null, internal
    /// feature buckets sit at the top level under codenames, and money is under `spend`.
    private let live = """
    {"five_hour":{"utilization":10.0,"resets_at":"2026-09-18T12:20:00.500592+00:00","limit_dollars":null},
     "seven_day":{"utilization":30.0,"resets_at":"2026-09-22T15:00:00.500613+00:00"},
     "seven_day_opus":null,"seven_day_sonnet":null,"seven_day_cowork":null,"tangelo":null,
     "nimbus_quill":{"utilization":0.0,"resets_at":null,"limit_dollars":null},
     "extra_usage":{"is_enabled":true,"monthly_limit":100000,"used_credits":12345.0,"utilization":12.345,
                    "currency":"GBP","decimal_places":2},
     "limits":[
       {"kind":"session","group":"session","percent":10,"severity":"normal","resets_at":"2026-09-18T12:20:00.500592+00:00","scope":null,"is_active":false},
       {"kind":"weekly_all","group":"weekly","percent":30,"severity":"normal","resets_at":"2026-09-22T15:00:00.500613+00:00","scope":null,"is_active":false},
       {"kind":"weekly_scoped","group":"weekly","percent":75,"severity":"warning","resets_at":"2026-09-22T14:59:59.500772+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}],
     "spend":{"used":{"amount_minor":12345,"currency":"GBP","exponent":2},"limit":{"amount_minor":100000,"currency":"GBP","exponent":2},
              "percent":12,"severity":"normal","enabled":true},
     "seven_day_breakdown":{"as_of":"2026-09-18T09:45:04+00:00","rows":[
       {"key":"claude_code","display_name":"Claude Code","percent":98},{"key":"chat","display_name":"Chats","percent":2},
       {"key":"cowork","display_name":"Cowork","percent":0}]}}
    """

    func testTheLimitsArrayIsTheSourceOfTruthWhenPresent() throws {
        let q = try XCTUnwrap(ClaudeQuota.parse(live))
        XCTAssertEqual(q.windows.map(\.key), ["session", "weekly_all", "weekly_scoped:Fable"],
                       "the per-model cap lives only in limits[]; codename buckets and extra_usage are not limits")
        XCTAssertEqual(q.window("weekly_scoped:Fable")?.percentUsed, 75)
        XCTAssertNotNil(q.window("weekly_scoped:Fable")?.resetsAt)
        XCTAssertEqual(q.fiveHour?.percentUsed, 10, "the legacy accessors read the new keys")
        XCTAssertEqual(q.sevenDay?.percentUsed, 30)
        XCTAssertNil(q.window("nimbus_quill"))
        XCTAssertNil(q.window("extra_usage"))
        XCTAssertEqual(q.windows.map(\.label), ["5-hour session", "Weekly · all models", "Weekly · Fable"])
    }

    func testSpendIsMoneyInTheAccountsCurrency() throws {
        let s = try XCTUnwrap(ClaudeQuota.parse(live)?.spend)
        XCTAssertEqual(s.currency, "GBP")
        XCTAssertEqual(s.usedMinor, 12345)
        XCTAssertEqual(s.limitMinor, 100000)
        XCTAssertEqual(s.percent, 12)
        XCTAssertEqual(s.summary, "£123.45 of £1,000.00")
    }

    func testSpendFallsBackToExtraUsageAndIsNilWhenCreditsAreOff() throws {
        let older = """
        {"five_hour":{"utilization":1.0,"resets_at":null},
         "extra_usage":{"is_enabled":true,"monthly_limit":100000,"used_credits":45678.0,"utilization":45.678,
                        "currency":"GBP","decimal_places":2}}
        """
        let s = try XCTUnwrap(ClaudeQuota.parse(older)?.spend)
        XCTAssertEqual(s.summary, "£456.78 of £1,000.00")
        XCTAssertEqual(s.percent, 46)
        XCTAssertNil(ClaudeQuota.parse(sample)?.spend, "is_enabled false → no spend row")
        XCTAssertEqual(ClaudeQuota.parse(sample)?.windows.map(\.key), ["five_hour", "seven_day", "seven_day_sonnet"])
        let usd = try XCTUnwrap(ClaudeQuota.parse(#"{"spend":{"used":{"amount_minor":250,"currency":"USD","exponent":2},"limit":{"amount_minor":5000,"currency":"USD","exponent":2},"enabled":true}}"#)?.spend)
        XCTAssertEqual(usd.summary, "$2.50 of $50.00")
        XCTAssertEqual(usd.percent, 5, "percent is derived when the endpoint omits it")
    }

    func testWeeklyBreakdownKeepsOnlyTheSurfacesThatUsedAnything() throws {
        let q = try XCTUnwrap(ClaudeQuota.parse(live))
        XCTAssertEqual(q.weekShares, [.init(name: "Claude Code", percent: 98), .init(name: "Chats", percent: 2)])
        XCTAssertEqual(ClaudeQuota.parse(sample)?.weekShares, [])
    }

    func testSurfacesUnknownPerModelWindows() throws {
        // The endpoint grows per-model weekly caps over time (Opus, Sonnet, Fable…);
        // shape-based parsing must surface keys it has never seen, known keys first.
        let json = """
        {
          "seven_day_fable": { "utilization": 42.0, "resets_at": "2026-04-16T03:00:00+00:00" },
          "five_hour": { "utilization": 10.0, "resets_at": null },
          "seven_day": { "utilization": 5.0, "resets_at": null },
          "extra_usage": { "is_enabled": false, "utilization": null }
        }
        """
        let q = try XCTUnwrap(ClaudeQuota.parse(json))
        XCTAssertEqual(q.windows.map(\.key), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(q.window("seven_day_fable")?.percentUsed, 42)
        XCTAssertNotNil(q.window("seven_day_fable")?.resetsAt)
        XCTAssertEqual(q.fiveHour?.percentUsed, 10)
        XCTAssertNil(q.window("extra_usage"), "null-utilization objects are not windows")
        let withCredits = json.replacingOccurrences(of: #""extra_usage": { "is_enabled": false, "utilization": null }"#,
                                                    with: #""extra_usage": { "is_enabled": false, "utilization": 56.0 }"#)
        XCTAssertNil(ClaudeQuota.parse(withCredits)?.window("extra_usage"), "extra_usage is the spend figure, never a limit row")
    }

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
