//
//  TranscriptFixtureTests.swift
//  Tests for SwiftAgentSession
//
//  Exercises the PARSING half of an adapter against a fixture, with no live agent session and
//  no `~/.claude` on disk — the property that lets an adapter for an agent you haven't
//  installed be written and kept honest.
//
//  Created by David Sherlock on 7/25/26.
//

import XCTest
@testable import AgentSession

/// Exercises the parsing half of an adapter against a fixture file, with no live agent session
/// and no project root, including the malformed lines that must be skipped.
final class TranscriptFixtureTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
    }

    /// Writes `lines` as a `.jsonl` transcript in a throwaway directory.
    private func fixture(_ lines: [String]) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcript-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.append(dir)
        let file = dir.appendingPathComponent("session.jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private let twoTurns = [
        #"{"type":"user","timestamp":"2026-07-25T10:00:00.000Z","message":{"content":"Add a retry"}}"#,
        #"{"type":"assistant","timestamp":"2026-07-25T10:00:04.000Z","message":{"content":[{"type":"text","text":"Adding backoff."}]}}"#,
        #"{"type":"assistant","timestamp":"2026-07-25T10:00:09.000Z","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"Up.swift"}}]}}"#,
        #"{"type":"assistant","timestamp":"2026-07-25T10:00:12.000Z","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"Up.swift","new_string":"retry()"}}]}}"#,
        #"{"type":"user","timestamp":"2026-07-25T10:05:00.000Z","message":{"content":[{"type":"text","text":"Cap it at 30s"}]}}"#,
        #"{"type":"assistant","timestamp":"2026-07-25T10:05:06.000Z","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"Up.swift","new_string":"min(30, d)"}}]}}"#,
    ]

    /// A shell tool call keeps its WHOLE command on the event: a heredoc's body, a `&&` chain,
    /// everything past the 120 characters the feed's `detail` shows. Other tools carry none.
    func testShellCommandIsKeptWhole() throws {
        let long = String(repeating: "x", count: 300)
        let file = try fixture([
            #"{"type":"user","timestamp":"2026-09-20T10:00:00.000Z","message":{"content":"Wipe the users"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-20T10:00:04.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"psql \"$DATABASE_URL\" <<'SQL'\nDELETE FROM users;\nSQL"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-20T10:00:05.000Z","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"echo LONG"}}]}}"#.replacingOccurrences(of: "LONG", with: long),
            #"{"type":"assistant","timestamp":"2026-09-20T10:00:06.000Z","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"a.sql","new_string":"DELETE FROM users;"}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-20T10:00:07.000Z","message":{"content":[{"type":"tool_use","name":"Grep","input":{"pattern":"DELETE"}}]}}"#,
        ])
        let events = ClaudeCodeAdapter().events(fromSession: file)
        let tools = events.filter { $0.kind == .toolUse || $0.kind == .fileEdit }
        XCTAssertEqual(tools.count, 4)
        XCTAssertEqual(tools[0].command, "psql \"$DATABASE_URL\" <<'SQL'\nDELETE FROM users;\nSQL", "the heredoc body is part of the command")
        XCTAssertEqual(tools[0].detail, "psql \"$DATABASE_URL\" <<'SQL'", "the feed's detail is still the first line")
        XCTAssertEqual(tools[1].command?.count, 5 + 300, "nothing is truncated")
        XCTAssertLessThan(tools[1].detail.count, 130, "the feed's detail is still capped")
        XCTAssertNil(tools[2].command, "an edit is not a command")
        XCTAssertNil(tools[3].command, "a search is not a command")
    }

    /// A message's usage and model ride on its FIRST event only; a replayed message (same id)
    /// bills nothing; a TodoWrite carries its items; a tool call carries its id.
    func testUsageModelTodosAndToolIDsRideOnEvents() throws {
        let file = try fixture([
            #"{"type":"user","timestamp":"2026-09-20T10:00:00.000Z","message":{"content":"Plan it"}}"#,
            #"{"type":"assistant","timestamp":"2026-09-20T10:00:04.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50},"content":[{"type":"text","text":"On it."},{"type":"tool_use","id":"tu_1","name":"TodoWrite","input":{"todos":[{"content":"Read the schema","status":"completed"},{"content":"Write the migration","status":"in_progress"},{"content":"Run tests","status":"pending"}]}}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-20T10:00:04.000Z","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":1000,"cache_creation_input_tokens":200,"cache_read_input_tokens":300,"output_tokens":50},"content":[{"type":"text","text":"On it."}]}}"#,
            #"{"type":"assistant","timestamp":"2026-09-20T10:00:09.000Z","message":{"id":"m2","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5},"content":[{"type":"tool_use","id":"tu_2","name":"Bash","input":{"command":"swift test"}}]}}"#,
        ])
        let events = ClaudeCodeAdapter().events(fromSession: file)
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[1].usage, TimelineEvent.Usage(input: 1000, cacheWrite: 200, cacheRead: 300, output: 50), "the message's first event carries the bill")
        XCTAssertEqual(events[1].model, "claude-opus-5")
        XCTAssertNil(events[2].usage, "the same message's second event carries none")
        XCTAssertEqual(events[2].model, "claude-opus-5", "but still says which model")
        XCTAssertEqual(events[2].todos, [TimelineEvent.TodoItem(content: "Read the schema", status: "completed"),
                                         TimelineEvent.TodoItem(content: "Write the migration", status: "in_progress"),
                                         TimelineEvent.TodoItem(content: "Run tests", status: "pending")])
        XCTAssertEqual(events[2].toolUseID, "tu_1")
        XCTAssertNil(events[3].usage, "a replayed message is not billed twice")
        XCTAssertEqual(events[4].usage?.output, 5)
        XCTAssertEqual(events[4].model, "claude-sonnet-5")
        XCTAssertEqual(events[4].toolUseID, "tu_2")
        XCTAssertNil(events[0].usage); XCTAssertNil(events[0].todos)
        XCTAssertGreaterThan(ModelPricing.cost(model: "claude-opus-5", input: 1000, cacheWrite: 200, cacheRead: 300, output: 50), 0)
    }

    func testParsesATranscriptFileWithNoLiveSession() throws {
        let file = try fixture(twoTurns)
        let events = ClaudeCodeAdapter().events(fromSession: file)

        XCTAssertEqual(events.count, 6)
        XCTAssertEqual(events.map(\.kind), [.userPrompt, .assistantText, .toolUse, .fileEdit,
                                            .userPrompt, .fileEdit])
        // A write tool is a fileEdit; a read tool is not — that split is what the review
        // surface keys off, so it's worth pinning.
        XCTAssertEqual(events[2].title, "Read")
        XCTAssertEqual(events[3].filePath, "Up.swift")
    }

    func testStringAndBlockUserContentBothParse() throws {
        // Claude Code writes a plain-string prompt sometimes and a content-block array other
        // times; both must yield a userPrompt or turn segmentation silently loses a boundary.
        let events = ClaudeCodeAdapter().events(fromSession: try fixture(twoTurns))
        XCTAssertEqual(events.filter { $0.kind == .userPrompt }.map(\.detail),
                       ["Add a retry", "Cap it at 30s"])
    }

    func testMalformedLinesAreSkippedNotFatal() throws {
        var lines = twoTurns
        lines.insert("not json at all", at: 2)
        lines.insert(#"{"type":"assistant"}"#, at: 4)     // no message
        let events = ClaudeCodeAdapter().events(fromSession: try fixture(lines))
        XCTAssertEqual(events.count, 6)                    // exactly the well-formed ones
    }

    func testTurnsSegmentFromAParsedFixture() throws {
        let events = ClaudeCodeAdapter().events(fromSession: try fixture(twoTurns))
        let turns = TurnBoundary.turns(in: events)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].editedFiles(in: events), ["Up.swift"])
        XCTAssertNotEqual(turns[0].id, turns[1].id)
    }

    func testMissingFileYieldsNoEventsRatherThanFailing() {
        let missing = URL(fileURLWithPath: "/nope/\(UUID().uuidString).jsonl")
        XCTAssertTrue(ClaudeCodeAdapter().events(fromSession: missing).isEmpty)
    }

    func testForeignFormatYieldsNoEvents() throws {
        // Another agent's transcript is not an error — it's simply not this adapter's.
        let file = try fixture([#"{"role":"user","parts":[{"text":"hello"}]}"#])
        XCTAssertTrue(ClaudeCodeAdapter().events(fromSession: file).isEmpty)
    }

    func testFixtureParseDoesNotDisturbAProjectPoll() throws {
        // The cache keys a fixture by its own path, so parsing one must not evict or corrupt
        // the snapshot a live project poll is using.
        let adapter = ClaudeCodeAdapter()
        let file = try fixture(twoTurns)
        let first = adapter.events(fromSession: file)
        _ = adapter.events(for: URL(fileURLWithPath: "/some/unrelated/project"))
        XCTAssertEqual(adapter.events(fromSession: file), first)
    }
}
