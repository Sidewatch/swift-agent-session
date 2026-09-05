//
//  ClaudeQuotaCacheTests.swift
//  AgentSessionTests
//
//  A call counter the fetch closures can share without capturing the test case.
//
//  Created by David Sherlock on 9/5/26.
//

import XCTest
@testable import AgentSession

/// A call counter the fetch closures can share without capturing the test case.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

/// Tests for `ClaudeQuotaCache`: fetches are shared and rate-limited, `force` bypasses the
/// cache, and a missing token yields nil without a fetch.
final class ClaudeQuotaCacheTests: XCTestCase {
    private static func quota(_ n: Int) -> ClaudeQuota? {
        ClaudeQuota.parse("{\"five_hour\":{\"utilization\":\(n),\"resets_at\":\"2026-01-01T00:00:00Z\"}}")
    }
    private func ask(_ cache: ClaudeQuotaCache, force: Bool = false, token: String? = "tok") -> ClaudeQuota? {
        let e = expectation(description: "delivered")
        final class Box: @unchecked Sendable { var got: ClaudeQuota? }
        let box = Box()
        cache.quota(force: force, token: { token }) { box.got = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        return box.got
    }

    func testFetchesOnceThenServesTheCachedValueUntilForced() {
        let calls = Counter()
        let cache = ClaudeQuotaCache(minRefreshInterval: 60) { _ in Self.quota(calls.next()) }
        XCTAssertNotNil(ask(cache)); XCTAssertEqual(calls.value, 1)
        XCTAssertNotNil(ask(cache)); XCTAssertEqual(calls.value, 1, "fresh: no second fetch")
        XCTAssertNotNil(ask(cache, force: true)); XCTAssertEqual(calls.value, 2, "force refetches")
    }

    func testAFailedRefreshKeepsTheLastGoodValueAndNoTokenMeansNoFetch() {
        let calls = Counter()
        let cache = ClaudeQuotaCache(minRefreshInterval: 0) { _ in calls.next() == 1 ? Self.quota(1) : nil }
        let first = ask(cache); XCTAssertNotNil(first)
        let second = ask(cache); XCTAssertEqual(calls.value, 2)
        XCTAssertEqual(second?.fiveHour?.utilization, first?.fiveHour?.utilization, "a failed refresh keeps the last good value")
        let untokened = ClaudeQuotaCache(minRefreshInterval: 0) { _ in XCTFail("must not fetch without a token"); return nil }
        XCTAssertNil(ask(untokened, token: nil))
    }
}
