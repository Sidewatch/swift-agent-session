//
//  AgentSessionTests.swift
//  Tests for SwiftAgentSession
//
//  Created by David Sherlock on 7/9/26.
//

import XCTest
@testable import AgentSession

final class AgentSessionTests: XCTestCase {

    // A unique project root per run so the derived transcript directory never
    // collides with a real Claude Code session under ~/.claude/projects.
    private let root = URL(fileURLWithPath: "/private/tmp/agent-session-tests-\(UUID().uuidString)")

    // The directory ClaudeCodeAdapter derives from `root`, created in setUp and
    // removed in tearDown so the test is self-cleaning.
    private var projectDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let encoded = String(root.path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        return home.appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
    }

    // A small synthetic Claude Code transcript: two user prompts (string + array
    // form), assistant prose, a file edit, a shell tool call, and a TodoWrite.
    private let transcript = """
    {"type":"user","timestamp":"2026-07-09T10:07:12.000Z","message":{"content":"Add a cron parser"}}
    {"type":"user","timestamp":"2026-07-09T10:07:20.000Z","message":{"content":[{"type":"text","text":"And write tests"}]}}
    {"type":"assistant","timestamp":"2026-07-09T10:08:00.000Z","message":{"model":"claude-sonnet-4","usage":{"input_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":200,"output_tokens":300},"content":[{"type":"text","text":"Sure, editing now.\\nSecond line ignored."},{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/foo/proj/Sources/App.swift"}}]}}
    {"type":"assistant","timestamp":"2026-07-09T10:09:00.000Z","message":{"model":"claude-sonnet-4","usage":{"input_tokens":3000,"cache_creation_input_tokens":0,"cache_read_input_tokens":1000,"output_tokens":200},"content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test\\nmore"}}]}}
    {"type":"assistant","timestamp":"2026-07-09T10:10:00.000Z","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Write tests","status":"in_progress"},{"content":"Ship it","status":"pending"}]}}]}}
    """

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let file = projectDir.appendingPathComponent("session.jsonl")
        try transcript.write(to: file, atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectDir)
    }

    // MARK: - Detection

    func testHasSessionAndActiveAgent() {
        XCTAssertTrue(ClaudeCodeAdapter().hasSession(for: root))
        let active = Agents.active(for: root)
        XCTAssertNotNil(active)
        XCTAssertEqual(active?.name, "Claude Code")
    }

    func testNoSessionForUnknownRoot() {
        let other = URL(fileURLWithPath: "/private/tmp/agent-session-nope-\(UUID().uuidString)")
        let adapter = ClaudeCodeAdapter()
        XCTAssertFalse(adapter.hasSession(for: other))
        XCTAssertNil(Agents.active(for: other))
        XCTAssertTrue(adapter.events(for: other).isEmpty)
        XCTAssertNil(adapter.usage(for: other))
        XCTAssertNil(adapter.summary(for: other))
    }

    // MARK: - Timeline

    func testEventsAreParsedInOrder() {
        let events = ClaudeCodeAdapter().events(for: root)
        XCTAssertEqual(events.count, 6)

        XCTAssertEqual(events[0].kind, .userPrompt)
        XCTAssertEqual(events[0].title, "You")
        XCTAssertEqual(events[0].detail, "Add a cron parser")
        XCTAssertNil(events[0].filePath)
        XCTAssertEqual(events[0].timestamp, "10:07")

        // User content given as an array of text blocks.
        XCTAssertEqual(events[1].kind, .userPrompt)
        XCTAssertEqual(events[1].detail, "And write tests")

        // Assistant prose — only the first line is kept.
        XCTAssertEqual(events[2].kind, .assistantText)
        XCTAssertEqual(events[2].title, "Claude")
        XCTAssertEqual(events[2].detail, "Sure, editing now.")

        // A tool call carrying a file_path becomes a file edit with a short path.
        XCTAssertEqual(events[3].kind, .fileEdit)
        XCTAssertEqual(events[3].title, "Edit")
        XCTAssertEqual(events[3].detail, ".../Sources/App.swift")
        XCTAssertEqual(events[3].filePath, "/Users/foo/proj/Sources/App.swift")

        // A shell tool call becomes a plain tool use, first line only, no path.
        XCTAssertEqual(events[4].kind, .toolUse)
        XCTAssertEqual(events[4].title, "Bash")
        XCTAssertEqual(events[4].detail, "swift test")
        XCTAssertNil(events[4].filePath)

        XCTAssertEqual(events[5].kind, .toolUse)
        XCTAssertEqual(events[5].title, "TodoWrite")
    }

    // MARK: - Telemetry

    func testUsageAggregation() {
        let usage = ClaudeCodeAdapter().usage(for: root)
        XCTAssertNotNil(usage)
        guard let u = usage else { return }

        // Last non-zero context window: 3000 + 0 + 1000 + 200.
        XCTAssertEqual(u.contextTokens, 4200)
        XCTAssertEqual(u.contextLimit, 200_000)
        XCTAssertEqual(u.outputTokens, 500)            // 300 + 200
        XCTAssertEqual(u.contextPercent, 2)            // 4200 / 200000 -> 2%

        // Sonnet (default) rates: input 3, cacheWrite 3.75, cacheRead 0.3, output 15 per 1e6.
        let expected = 0.009435 + 0.0123
        XCTAssertEqual(u.costUSD, expected, accuracy: 1e-9)
    }

    // MARK: - Plan vs actual

    func testSummaryCollectsEditsAndTodos() {
        let summary = ClaudeCodeAdapter().summary(for: root)
        XCTAssertNotNil(summary)
        guard let s = summary else { return }

        XCTAssertEqual(s.editedFiles, ["/Users/foo/proj/Sources/App.swift"])

        XCTAssertEqual(s.todos.count, 2)
        XCTAssertEqual(s.todos[0].text, "Write tests")
        XCTAssertEqual(s.todos[0].status, "in_progress")
        XCTAssertEqual(s.todos[1].text, "Ship it")
        XCTAssertEqual(s.todos[1].status, "pending")
    }
}
