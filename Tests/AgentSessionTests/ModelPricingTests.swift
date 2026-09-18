//
//  ModelPricingTests.swift
//  AgentSessionTests
//
//  The per-generation list prices against the published table, by the ids Claude Code writes.
//
//  Created by David Sherlock on 9/18/26.
//

import XCTest
@testable import AgentSession

/// Tests for `ModelPricing`: the published table by generation, the generation parser for
/// both id shapes, and the version-less fallback.
final class ModelPricingTests: XCTestCase {

    private func rates(_ id: String) -> [Double] {
        let r = ModelPricing.rates(for: id)
        return [r.input, r.cacheWrite, r.cacheRead, r.output]
    }

    /// platform.claude.com/docs/en/about-claude/pricing, read 18 Sep 2026 — input, 5-minute cache
    /// write, cache read, output per million. The ids are the ones seen in real transcripts.
    func testRatesFollowThePublishedTableByGeneration() {
        XCTAssertEqual(rates("claude-fable-5-1"), [10, 12.5, 0.25, 50])
        XCTAssertEqual(rates("claude-mythos-5-1"), [10, 12.5, 0.25, 50])
        XCTAssertEqual(rates("claude-fable-5"), [10, 12.5, 1, 50])
        XCTAssertEqual(rates("claude-opus-5"), [5, 6.25, 0.5, 25])
        XCTAssertEqual(rates("claude-opus-4-8"), [5, 6.25, 0.5, 25])
        XCTAssertEqual(rates("claude-opus-4-5-20251101"), [5, 6.25, 0.5, 25])
        XCTAssertEqual(rates("claude-opus-4-1-20250805"), [15, 18.75, 1.5, 75])
        XCTAssertEqual(rates("claude-sonnet-5"), [2, 2.5, 0.2, 10])
        XCTAssertEqual(rates("claude-sonnet-4-5"), [3, 3.75, 0.3, 15])
        XCTAssertEqual(rates("claude-sonnet-4"), [3, 3.75, 0.3, 15])
        XCTAssertEqual(rates("claude-haiku-4-5-20251001"), [1, 1.25, 0.1, 5])
        XCTAssertEqual(rates("claude-3-5-haiku-20241022"), [0.8, 1, 0.08, 4])
    }

    func testGenerationIsReadFromEitherIdShape() {
        func gen(_ id: String) -> [Int]? { ModelPricing.generation(of: id).map { [$0.major, $0.minor] } }
        XCTAssertEqual(gen("claude-opus-4-8"), [4, 8])
        XCTAssertEqual(gen("claude-opus-5"), [5, 0])
        XCTAssertEqual(gen("claude-haiku-4-5-20251001"), [4, 5], "the date is not a version")
        XCTAssertEqual(gen("claude-sonnet-4-20250514"), [4, 0])
        XCTAssertEqual(gen("claude-3-5-sonnet-20241022"), [3, 5], "the older shape puts the version first")
        XCTAssertNil(gen("<synthetic>"))
    }

    func testAnIdWithNoVersionTakesItsFamilysOlderRates() {
        XCTAssertEqual(rates("opus"), [15, 18.75, 1.5, 75])
        XCTAssertEqual(rates("<synthetic>"), [3, 3.75, 0.3, 15])
    }

    func testCostAddsTheFourTiers() {
        let usd = ModelPricing.cost(model: "claude-opus-5", input: 1_000_000, cacheWrite: 1_000_000,
                                    cacheRead: 1_000_000, output: 1_000_000)
        XCTAssertEqual(usd, 5 + 6.25 + 0.5 + 25, accuracy: 1e-9)
    }
}
