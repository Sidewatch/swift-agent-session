//
//  UsageSessionStatsTests.swift
//  AgentSessionTests
//
//  The longest session and the most active day, as Claude Code's own stats screen counts them.
//
//  Created by David Sherlock on 9/18/26.
//

import XCTest
@testable import AgentSession

/// Tests for the two stats the Usage report shares with Claude Code's `/stats` screen: the
/// longest session (a transcript's first message to its last) and the most active day (the
/// local day with the most tokens).
final class UsageSessionStatsTests: XCTestCase {

    private func line(_ ts: String, id: String, output: Int) -> String {
        #"{"timestamp":"\#(ts)","requestId":"\#(id)","message":{"id":"\#(id)","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":\#(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }

    func testLongestSessionAndMostActiveDay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-stats-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("-Users-x-dev-app")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Session A spans 90 minutes across three messages (the middle one out of order);
        // session B is ten minutes but carries far more tokens on a different day.
        let a = [line("2026-09-01T10:00:00Z", id: "a1", output: 10),
                 line("2026-09-01T11:30:00Z", id: "a3", output: 10),
                 line("2026-09-01T10:40:00Z", id: "a2", output: 10)].joined(separator: "\n")
        let b = [line("2026-09-03T10:00:00Z", id: "b1", output: 5_000),
                 line("2026-09-03T10:10:00Z", id: "b2", output: 5_000)].joined(separator: "\n")
        try (a + "\n").write(to: proj.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try (b + "\n").write(to: proj.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)

        let report = UsageAggregator.report(projectsRoot: root)
        XCTAssertEqual(report.sessionCount, 2)
        XCTAssertEqual(report.longestSession, 90 * 60, "first to last message of the longest transcript, order in the file ignored")
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.timeZone = .current; day.dateFormat = "yyyy-MM-dd"
        let bDay = day.string(from: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-03T10:00:00Z")))
        XCTAssertEqual(report.mostActiveDay, bDay, "by tokens, not by message count")
    }

    func testNoTimestampsMeansNoLongestSessionButStillASession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-stats-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("-Users-x-dev-app")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bare = #"{"requestId":"r1","message":{"id":"m1","model":"claude-sonnet-4-5","usage":{"input_tokens":10,"output_tokens":10}}}"#
        try (bare + "\n").write(to: proj.appendingPathComponent("s.jsonl"), atomically: true, encoding: .utf8)
        let report = UsageAggregator.report(projectsRoot: root)
        XCTAssertEqual(report.sessionCount, 1)
        XCTAssertNil(report.longestSession)
        XCTAssertNil(report.mostActiveDay)
        XCTAssertNil(UsageReport.empty.longestSession)
    }
}
