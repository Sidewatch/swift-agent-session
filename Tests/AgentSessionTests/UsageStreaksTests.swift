//
//  UsageStreaksTests.swift
//  AgentSessionTests
//
//  Claude writes a response line more than once when a turn is retried; the same `message.id`
//  must be counted once, or the bill doubles.
//
//  Created by David Sherlock on 7/19/26.
//

import XCTest
@testable import AgentSession

/// Tests for `UsageStreaks`: day-by-day activity streaks computed in the local time zone,
/// including the empty case.
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

/// Pins that a response line Claude wrote twice (a retried turn, same `message.id`) is counted
/// once in the usage report.
final class UsageReportDedupeTests: XCTestCase {
    /// Claude writes a response line more than once when a turn is retried; the same
    /// `message.id` must be counted once, or the bill doubles.
    func testDuplicateResponseLinesCountOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("-Users-x-dev-app")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let line = #"{"timestamp":"2026-09-05T10:00:00Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let other = line.replacingOccurrences(of: "msg-1", with: "msg-2").replacingOccurrences(of: "req-1", with: "req-2")
        try (line + "\n" + line + "\n" + other + "\n").write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let report = UsageAggregator.report(projectsRoot: root)
        XCTAssertEqual(report.messageCount, 2, "three lines, two distinct ids")
        XCTAssertEqual(report.inputTokens, 200)
        XCTAssertEqual(report.outputTokens, 100)
    }
}
