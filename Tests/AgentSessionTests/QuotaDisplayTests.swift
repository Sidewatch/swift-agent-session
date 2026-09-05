//
//  QuotaDisplayTests.swift
//  AgentSessionTests
//
//  Tests for the quota display helpers: each `ClaudeQuota.NamedWindow` key maps to its human
//  label.
//
//  Created by David Sherlock on 9/5/26.
//

import XCTest
@testable import AgentSession

/// Tests for the quota display helpers: each `ClaudeQuota.NamedWindow` key maps to its human
/// label.
final class QuotaDisplayTests: XCTestCase {

    private func named(_ key: String) -> ClaudeQuota.NamedWindow {
        ClaudeQuota.NamedWindow(key: key, window: ClaudeQuota.Window(utilization: 0, resetsAt: nil))
    }

    func testWindowLabels() {
        XCTAssertEqual(named("five_hour").label, "5-hour session")
        XCTAssertEqual(named("seven_day").label, "Weekly")
        XCTAssertEqual(named("seven_day_opus").label, "Weekly · Opus")
        XCTAssertEqual(named("seven_day_fable").label, "Weekly · Fable")
        XCTAssertEqual(named("some_new_cap").label, "Some New Cap")
    }

    func testResetDescriptions() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        func window(_ offset: TimeInterval?) -> ClaudeQuota.Window {
            ClaudeQuota.Window(utilization: 0, resetsAt: offset.map { now.addingTimeInterval($0) })
        }
        XCTAssertNil(window(nil).resetDescription(now: now))
        XCTAssertEqual(window(-1).resetDescription(now: now), "resets now")
        XCTAssertEqual(window(5 * 60).resetDescription(now: now), "resets in 5m")
        XCTAssertEqual(window(90 * 60).resetDescription(now: now), "resets in 1h 30m")
        XCTAssertEqual(window(26 * 3600).resetDescription(now: now), "resets in 1d 2h")
    }

    func testCompactCounts() {
        XCTAssertEqual(999.compactCount, "999")
        XCTAssertEqual(1_500.compactCount, "1.5K")
        XCTAssertEqual(2_500_000.compactCount, "2.5M")
        XCTAssertEqual(3_000_000_000.compactCount, "3.0B")
    }
}
