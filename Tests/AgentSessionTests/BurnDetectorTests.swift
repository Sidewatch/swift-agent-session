//
//  BurnDetectorTests.swift
//  AgentSessionTests
//
//  Tests for loop detection over a timeline.
//
//  Created by David Sherlock on 9/5/26.
//

import XCTest
@testable import AgentSession

final class BurnDetectorTests: XCTestCase {

    private func tool(_ command: String) -> TimelineEvent {
        TimelineEvent(kind: .toolUse, title: "Bash", detail: command, filePath: nil, timestamp: "2026-09-05T10:00:00Z")
    }
    private func prose() -> TimelineEvent { TimelineEvent(kind: .assistantText, title: "", detail: "thinking", filePath: nil, timestamp: "t") }
    private func prompt() -> TimelineEvent { TimelineEvent(kind: .userPrompt, title: "", detail: "do it", filePath: nil, timestamp: "t") }

    func testTheSameCommandThreeTimesStartsAnEpisode() {
        var d = BurnDetector()
        XCTAssertEqual(d.update(events: [tool("swift build"), tool("swift build")]), .none, "two is not yet a loop")
        XCTAssertEqual(d.update(events: (1...3).map { _ in tool("swift build") }), .started(notice: "agent may be looping: swift build ×3"))
        XCTAssertEqual(d.update(events: (1...3).map { _ in tool("swift build") }), .none, "the same count does not re-fire")
        XCTAssertEqual(d.update(events: (1...4).map { _ in tool("swift build") }), .updated(notice: "agent may be looping: swift build ×4"))
        XCTAssertTrue(d.isLooping)
    }

    func testDifferentScriptsSharingAFirstLineAreNotALoop() {
        var d = BurnDetector()
        let scripts = ["cd /p; python3 - <<'EOF'\nprint('one')\nEOF", "cd /p; python3 - <<'EOF'\nprint('two')\nEOF", "cd /p; python3 - <<'EOF'\nprint('three')\nEOF"]
        XCTAssertEqual(d.update(events: scripts.map(tool)), .none)
    }

    func testProseIsSkippedButAPromptOrADistinctCallEndsTheRun() {
        var d = BurnDetector()
        XCTAssertEqual(d.update(events: [tool("ls"), prose(), tool("ls"), prose(), tool("ls")]), .started(notice: "agent may be looping: ls ×3"))
        XCTAssertEqual(d.update(events: [tool("ls"), tool("ls"), prompt(), tool("ls")]), .ended, "a prompt in the window ends the run")
        XCTAssertEqual(d.update(events: [tool("ls"), tool("ls"), tool("git status"), tool("ls")]), .none, "no episode, nothing to end")
    }

    func testTheNoticeNamesTheFirstLineAndBookkeepingIsIgnored() {
        var d = BurnDetector()
        let empty = TimelineEvent(kind: .toolUse, title: "TodoWrite", detail: "", filePath: nil, timestamp: "t")
        let events = [tool("cd /p; swift test\n# same script"), empty, tool("cd /p; swift test\n# same script"), tool("cd /p; swift test\n# same script")]
        XCTAssertEqual(d.update(events: events), .started(notice: "agent may be looping: cd /p; swift test ×3"))
    }

    func testResetForgetsTheEpisode() {
        var d = BurnDetector()
        _ = d.update(events: (1...3).map { _ in tool("make") })
        d.reset()
        XCTAssertFalse(d.isLooping)
        XCTAssertEqual(d.update(events: (1...3).map { _ in tool("make") }), .started(notice: "agent may be looping: make ×3"), "a fresh episode after reset")
    }
}
