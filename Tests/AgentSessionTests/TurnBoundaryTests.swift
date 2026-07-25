//
//  TurnBoundaryTests.swift
//  Tests for SwiftAgentSession
//
//  Created by David Sherlock on 7/25/26.
//

import XCTest
@testable import AgentSession

final class TurnBoundaryTests: XCTestCase {

    private func event(_ kind: TimelineEvent.Kind, _ detail: String, file: String? = nil,
                       at timestamp: String = "10:00") -> TimelineEvent {
        TimelineEvent(kind: kind, title: "t", detail: detail, filePath: file, timestamp: timestamp)
    }

    func testTurnsSplitOnEveryUserPrompt() {
        let events = [
            event(.userPrompt, "first ask", at: "10:00"),
            event(.assistantText, "working"),
            event(.fileEdit, "edit", file: "a.swift"),
            event(.userPrompt, "second ask", at: "10:05"),
            event(.fileEdit, "edit", file: "b.swift"),
        ]
        let turns = TurnBoundary.turns(in: events)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].start, 0)
        XCTAssertEqual(turns[0].end, 2)
        XCTAssertEqual(turns[0].prompt, "first ask")
        XCTAssertEqual(turns[0].timestamp, "10:00")
        XCTAssertEqual(turns[0].count, 3)
        // The final turn runs to the end of the feed.
        XCTAssertEqual(turns[1].start, 3)
        XCTAssertEqual(turns[1].end, 4)
    }

    func testEventsBeforeTheFirstPromptBelongToNoTurn() {
        // A resumed session replays a tail with no prompt in front of it; folding that into
        // the first turn would attribute work to a prompt that didn't cause it.
        let events = [
            event(.assistantText, "orphan"),
            event(.fileEdit, "edit", file: "old.swift"),
            event(.userPrompt, "the ask"),
            event(.fileEdit, "edit", file: "new.swift"),
        ]
        let turns = TurnBoundary.turns(in: events)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].start, 2)
        XCTAssertEqual(turns[0].editedFiles(in: events), ["new.swift"])
    }

    func testNoPromptsMeansNoTurns() {
        XCTAssertTrue(TurnBoundary.turns(in: [event(.assistantText, "x")]).isEmpty)
        XCTAssertTrue(TurnBoundary.turns(in: []).isEmpty)
    }

    func testConsecutivePromptsProduceASingleEventTurn() {
        let events = [event(.userPrompt, "a"), event(.userPrompt, "b")]
        let turns = TurnBoundary.turns(in: events)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].count, 1)
        XCTAssertEqual(turns[0].start, turns[0].end)
    }

    func testTurnContainingIndex() {
        let events = [
            event(.userPrompt, "a"), event(.fileEdit, "e", file: "x"),
            event(.userPrompt, "b"), event(.fileEdit, "e", file: "y"),
        ]
        let turns = TurnBoundary.turns(in: events)
        XCTAssertEqual(TurnBoundary.turn(containing: 1, in: turns)?.prompt, "a")
        XCTAssertEqual(TurnBoundary.turn(containing: 2, in: turns)?.prompt, "b")
        XCTAssertEqual(TurnBoundary.turn(containing: 3, in: turns)?.prompt, "b")
        XCTAssertNil(TurnBoundary.turn(containing: 99, in: turns))
    }

    func testTurnContainingIndexBeforeFirstPromptIsNil() {
        let events = [event(.assistantText, "orphan"), event(.userPrompt, "a")]
        XCTAssertNil(TurnBoundary.turn(containing: 0, in: TurnBoundary.turns(in: events)))
    }

    func testEditedFilesDeduplicatesAndKeepsFirstTouchedOrder() {
        let events = [
            event(.userPrompt, "a"),
            event(.fileEdit, "e", file: "b.swift"),
            event(.fileEdit, "e", file: "a.swift"),
            event(.fileEdit, "e", file: "b.swift"),
            event(.toolUse, "ls", file: "ignored.swift"),
        ]
        let turn = TurnBoundary.turns(in: events)[0]
        // Order is first-touched, not sorted; only .fileEdit counts, so the tool row's path
        // must not appear.
        XCTAssertEqual(turn.editedFiles(in: events), ["b.swift", "a.swift"])
    }

    func testEditedFilesOnOutOfRangeTurnIsEmpty() {
        let turn = TurnBoundary(start: 5, end: 9, prompt: "x", timestamp: "")
        XCTAssertTrue(turn.editedFiles(in: [event(.userPrompt, "a")]).isEmpty)
    }
}
