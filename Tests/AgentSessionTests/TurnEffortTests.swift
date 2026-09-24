//
//  TurnEffortTests.swift
//  Tests for SwiftAgentSession
//
//  Tests for a turn's effort: tool calls counted, the last model kept, the cost summed at the
//  messages' own usage, and the row labels.
//
//  Created by David Sherlock on 9/22/26.
//

import XCTest
@testable import AgentSession

/// Tests for `TurnBoundary.effort(in:)` and `TurnEffort`'s labels.
final class TurnEffortTests: XCTestCase {

    private func event(_ kind: TimelineEvent.Kind, _ detail: String = "", usage: TimelineEvent.Usage? = nil,
                       model: String? = nil) -> TimelineEvent {
        TimelineEvent(kind: kind, title: "t", detail: detail, filePath: nil, timestamp: "10:00",
                      usage: usage, model: model)
    }

    private let usage = TimelineEvent.Usage(input: 4000, cacheWrite: 0, cacheRead: 12000, output: 300)

    func testEffortCountsToolCallsAndFileEditsKeepsTheLastModelAndSumsTheCost() {
        let events = [
            event(.userPrompt, "do it"),
            event(.assistantText, "on it", usage: usage, model: "claude-sonnet-5"),
            event(.toolUse, "swift build"),
            event(.fileEdit, "A.swift"),
            event(.assistantText, "done", usage: usage, model: "claude-opus-5"),
            event(.userPrompt, "next"),
            event(.toolUse, "ls"),
        ]
        let turns = TurnBoundary.turns(in: events)
        let first = turns[0].effort(in: events)
        XCTAssertEqual(first.toolCalls, 2, "a tool call and a file edit; prose is not a call")
        XCTAssertEqual(first.model, "claude-opus-5", "the LAST model seen in the turn")
        let expected = ModelPricing.cost(model: "claude-sonnet-5", input: 4000, cacheWrite: 0, cacheRead: 12000, output: 300)
            + ModelPricing.cost(model: "claude-opus-5", input: 4000, cacheWrite: 0, cacheRead: 12000, output: 300)
        XCTAssertEqual(first.cost, expected, accuracy: 1e-9, "each message at its OWN model's price")
        XCTAssertGreaterThan(first.cost, 0)
        XCTAssertEqual(turns[1].effort(in: events), TurnEffort(toolCalls: 1, model: nil, cost: 0))
    }

    func testAUsageRecordBeforeAnyModelNameIsPricedAtTheTurnsLastModelOrTheDefault() {
        let events = [
            event(.userPrompt, "go"),
            event(.assistantText, "…", usage: usage),                       // no model on this message
            event(.assistantText, "…", model: "claude-haiku-4-5-20251001"),
        ]
        let effort = TurnBoundary.turns(in: events)[0].effort(in: events)
        XCTAssertEqual(effort.cost, ModelPricing.cost(model: "claude", input: 4000, cacheWrite: 0, cacheRead: 12000, output: 300), accuracy: 1e-9,
                       "no model seen yet when the usage arrived: the default generation")
        XCTAssertEqual(effort.model, "claude-haiku-4-5-20251001")
    }

    func testATurnOutsideTheTimelineHasNoEffort() {
        let stale = TurnBoundary(start: 5, end: 9, prompt: "gone", timestamp: "")
        XCTAssertEqual(stale.effort(in: [event(.userPrompt)]), .none)
        XCTAssertEqual(TurnEffort.none.toolCalls, 0)
    }

    func testModelIdsReadAsFamilyAndVersion() {
        XCTAssertEqual(TurnEffort.shortModel("claude-opus-5"), "opus 5")
        XCTAssertEqual(TurnEffort.shortModel("claude-haiku-4-5-20251001"), "haiku 4.5", "two numeric parts, the date dropped")
        XCTAssertEqual(TurnEffort.shortModel("claude-sonnet-5"), "sonnet 5")
        XCTAssertEqual(TurnEffort.shortModel("claude"), "claude", "no version: the family alone")
        XCTAssertNil(TurnEffort.shortModel(nil))
        XCTAssertEqual(TurnEffort(toolCalls: 1, model: "claude-opus-5", cost: 0).modelLabel, "opus 5")
    }

    func testCostLabelsShowCentsUnderTenDollarsWholeDollarsAboveAndNothingUnderHalfACent() {
        XCTAssertNil(TurnEffort.costLabel(0.004))
        XCTAssertEqual(TurnEffort.costLabel(0.005), "$0.01")
        XCTAssertEqual(TurnEffort.costLabel(0.42), "$0.42")
        XCTAssertEqual(TurnEffort.costLabel(9.999), "$10.00")
        XCTAssertEqual(TurnEffort.costLabel(12.3), "$12")
        XCTAssertEqual(TurnEffort(toolCalls: 1, model: nil, cost: 0.42).costLabel, "$0.42")
        XCTAssertNil(TurnEffort.none.costLabel)
    }
}
