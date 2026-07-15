//
//  AgentSessionTests.swift
//  Tests for SwiftAgentSession
//
//  Created by David Sherlock on 7/9/26.
//

import XCTest
@testable import AgentSession

final class AgentSessionTests: XCTestCase {

    // Every test runs against a throwaway projects container (the internal
    // `projectsRoot` seam), never the real ~/.claude/projects.
    private var projectsRoot: URL!

    // The fake project working directory a transcript is keyed to.
    private let root = URL(fileURLWithPath: "/private/tmp/agent-session-tests/project")

    private var adapter: ClaudeCodeAdapter { ClaudeCodeAdapter(projectsRoot: projectsRoot) }

    // The directory ClaudeCodeAdapter derives from `root` inside `projectsRoot`.
    private var projectDir: URL {
        let encoded = String(root.path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        return projectsRoot.appendingPathComponent(encoded, isDirectory: true)
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
        projectsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-session-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try write(transcript)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    // Overwrites this test's session transcript.
    private func write(_ transcript: String) throws {
        let file = projectDir.appendingPathComponent("session.jsonl")
        try transcript.write(to: file, atomically: true, encoding: .utf8)
    }

    // The local-clock HH:MM the adapter is expected to render for a UTC instant.
    private func localHHMM(_ iso: String) -> String {
        let isoF = ISO8601DateFormatter()
        isoF.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f.string(from: isoF.date(from: iso)!)
    }

    // MARK: - Isolation

    // The production init must still point at the real home; the seam only
    // changes where an explicitly-constructed adapter looks.
    func testDefaultInitPointsAtHomeClaudeProjects() {
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        XCTAssertEqual(ClaudeCodeAdapter().projectsRoot.path, expected.path)
    }

    // MARK: - Detection

    func testHasSessionAndActiveAgent() {
        XCTAssertTrue(adapter.hasSession(for: root))
        let active = Agents.active(for: root, in: [adapter])
        XCTAssertNotNil(active)
        XCTAssertEqual(active?.name, "Claude Code")
    }

    func testActiveReturnsFirstMatchingAdapter() {
        // A second adapter rooted at an empty container must lose to the one
        // that actually has a session, regardless of list position.
        let empty = ClaudeCodeAdapter(projectsRoot: projectsRoot.appendingPathComponent("nothing-here"))
        XCTAssertEqual(Agents.active(for: root, in: [empty, adapter])?.name, "Claude Code")
        XCTAssertNil(Agents.active(for: root, in: [empty]))
        XCTAssertNil(Agents.active(for: root, in: []))
    }

    func testNoSessionForUnknownRoot() {
        let other = URL(fileURLWithPath: "/private/tmp/agent-session-nope-\(UUID().uuidString)")
        XCTAssertFalse(adapter.hasSession(for: other))
        XCTAssertNil(Agents.active(for: other, in: [adapter]))
        XCTAssertTrue(adapter.events(for: other).isEmpty)
        XCTAssertNil(adapter.usage(for: other))
        XCTAssertNil(adapter.summary(for: other))
    }

    // A project directory that exists but holds no .jsonl files is not a session.
    func testProjectDirWithoutTranscriptsIsNotASession() throws {
        let files = try FileManager.default.contentsOfDirectory(at: projectDir, includingPropertiesForKeys: nil)
        for f in files { try FileManager.default.removeItem(at: f) }
        XCTAssertFalse(adapter.hasSession(for: root))
        XCTAssertNil(Agents.active(for: root, in: [adapter]))
    }

    // MARK: - Timeline

    func testEventsAreParsedInOrder() {
        let events = adapter.events(for: root)
        XCTAssertEqual(events.count, 6)

        XCTAssertEqual(events[0].kind, .userPrompt)
        XCTAssertEqual(events[0].title, "You")
        XCTAssertEqual(events[0].detail, "Add a cron parser")
        XCTAssertNil(events[0].filePath)
        XCTAssertEqual(events[0].timestamp, localHHMM("2026-07-09T10:07:12.000Z"))

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

    // Read-only tools that carry a path (Read, Grep, Glob, LS) must stay .toolUse —
    // only Edit/Write/MultiEdit/NotebookEdit are file edits.
    func testReadOnlyToolsWithPathsAreNotFileEdits() throws {
        try write("""
        {"type":"assistant","timestamp":"2026-07-09T10:08:00.000Z","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/proj/App.swift"}},{"type":"tool_use","name":"Grep","input":{"pattern":"foo","path":"/proj/Sources"}},{"type":"tool_use","name":"Write","input":{"file_path":"/proj/New.swift"}}]}}
        """)
        let events = adapter.events(for: root)
        XCTAssertEqual(events.count, 3)

        XCTAssertEqual(events[0].kind, .toolUse)
        XCTAssertEqual(events[0].title, "Read")
        XCTAssertEqual(events[0].filePath, "/proj/App.swift")   // still navigable

        XCTAssertEqual(events[1].kind, .toolUse)
        XCTAssertEqual(events[1].title, "Grep")
        XCTAssertEqual(events[1].filePath, "/proj/Sources")

        XCTAssertEqual(events[2].kind, .fileEdit)
        XCTAssertEqual(events[2].title, "Write")
    }

    // Timestamps in the transcript are UTC Zulu; the timeline must show local time.
    func testTimestampsAreConvertedToLocalTime() {
        let events = adapter.events(for: root)
        XCTAssertEqual(events[3].timestamp, localHHMM("2026-07-09T10:08:00.000Z"))
    }

    // NotebookEdit's path parameter is notebook_path, not file_path — it must still
    // count as a file edit with a navigable path in both events() and summary().
    func testNotebookEditUsesNotebookPath() throws {
        try write("""
        {"type":"assistant","timestamp":"2026-07-09T10:08:00.000Z","message":{"content":[{"type":"tool_use","name":"NotebookEdit","input":{"notebook_path":"/proj/analysis.ipynb","cell_id":"c1","new_source":"x = 1"}}]}}
        """)
        let events = adapter.events(for: root)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .fileEdit)
        XCTAssertEqual(events[0].detail, "/proj/analysis.ipynb")   // ≤2 components: kept whole
        XCTAssertEqual(events[0].filePath, "/proj/analysis.ipynb")

        XCTAssertEqual(adapter.summary(for: root)?.editedFiles, ["/proj/analysis.ipynb"])
    }

    // MARK: - Telemetry

    func testUsageAggregation() {
        let usage = adapter.usage(for: root)
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

    // Claude Code writes one JSONL line per assistant content block, each repeating the
    // same message.id and an identical usage object — the response must be counted once.
    func testUsageDeduplicatesRepeatedMessageIDs() throws {
        try write("""
        {"type":"assistant","timestamp":"2026-07-09T10:08:00.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-sonnet-4","usage":{"input_tokens":3000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":200},"content":[{"type":"text","text":"Editing now."}]}}
        {"type":"assistant","timestamp":"2026-07-09T10:08:01.000Z","requestId":"req_1","message":{"id":"msg_1","model":"claude-sonnet-4","usage":{"input_tokens":3000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":200},"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/proj/App.swift"}}]}}
        {"type":"assistant","timestamp":"2026-07-09T10:09:00.000Z","requestId":"req_2","message":{"id":"msg_2","model":"claude-sonnet-4","usage":{"input_tokens":4000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":100},"content":[{"type":"text","text":"Done."}]}}
        """)
        let usage = adapter.usage(for: root)
        XCTAssertNotNil(usage)
        guard let u = usage else { return }

        XCTAssertEqual(u.outputTokens, 300)            // 200 (once) + 100, not 200 + 200 + 100
        XCTAssertEqual(u.contextTokens, 4100)          // last usage line: 4000 + 100

        // msg_1 counted once (3000 in, 200 out) + msg_2 (4000 in, 100 out) at Sonnet rates.
        let expected = (3000.0 / 1e6 * 3 + 200.0 / 1e6 * 15) + (4000.0 / 1e6 * 3 + 100.0 / 1e6 * 15)
        XCTAssertEqual(u.costUSD, expected, accuracy: 1e-9)
    }

    // With message.id absent, dedupe falls back to requestId.
    func testUsageDedupeFallsBackToRequestID() throws {
        try write("""
        {"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-4","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50},"content":[]}}
        {"type":"assistant","requestId":"req_1","message":{"model":"claude-sonnet-4","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50},"content":[]}}
        """)
        let u = try XCTUnwrap(adapter.usage(for: root))
        XCTAssertEqual(u.outputTokens, 50)             // deduped on requestId
    }

    // With neither message.id nor requestId there is no dedupe key; every line
    // counts (the documented conservative fallback) — and it must not crash.
    func testUsageWithoutAnyIDCountsEachLine() throws {
        try write("""
        {"type":"assistant","message":{"model":"claude-sonnet-4","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50},"content":[]}}
        {"type":"assistant","message":{"model":"claude-sonnet-4","usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":50},"content":[]}}
        """)
        let u = try XCTUnwrap(adapter.usage(for: root))
        XCTAssertEqual(u.outputTokens, 100)
    }

    // Lines with message but no usage object contribute nothing to telemetry;
    // a transcript with no usage at all yields nil, not a zeroed struct.
    func testUsageMissingUsageFields() throws {
        try write("""
        {"type":"assistant","message":{"model":"claude-sonnet-4","content":[{"type":"text","text":"no usage here"}]}}
        {"type":"user","message":{"content":"hi"}}
        """)
        XCTAssertNil(adapter.usage(for: root))

        // Mixed: only the line carrying usage counts.
        try write("""
        {"type":"assistant","message":{"model":"claude-sonnet-4","content":[{"type":"text","text":"no usage"}]}}
        {"type":"assistant","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":2000,"output_tokens":10},"content":[]}}
        """)
        let u = try XCTUnwrap(adapter.usage(for: root))
        XCTAssertEqual(u.outputTokens, 10)
        XCTAssertEqual(u.contextTokens, 2010)          // missing cache fields default to 0
    }

    // A usage object of the wrong JSON type must be skipped, not crash.
    func testUsageWithWrongTypedFieldsIsSkipped() throws {
        try write("""
        {"type":"assistant","message":{"usage":"not-a-dict","content":[]}}
        {"type":"assistant","message":{"usage":{"input_tokens":"three thousand","output_tokens":25},"content":[]}}
        """)
        let u = try XCTUnwrap(adapter.usage(for: root))
        XCTAssertEqual(u.outputTokens, 25)             // string token count treated as 0
        XCTAssertEqual(u.contextTokens, 25)
    }

    // MARK: - Malformed input (the parser must never crash and must skip bad lines)

    func testEmptyFile() throws {
        try write("")
        XCTAssertTrue(adapter.hasSession(for: root))    // the file exists…
        XCTAssertTrue(adapter.events(for: root).isEmpty)
        XCTAssertNil(adapter.usage(for: root))          // …but has no telemetry
        let s = try XCTUnwrap(adapter.summary(for: root))
        XCTAssertTrue(s.editedFiles.isEmpty)
        XCTAssertTrue(s.todos.isEmpty)
    }

    // A truncated final line (agent killed mid-write) must be skipped.
    func testTruncatedLastLineIsSkipped() throws {
        try write("""
        {"type":"user","timestamp":"2026-07-09T10:07:12.000Z","message":{"content":"Hello"}}
        {"type":"assistant","timestamp":"2026-07-09T10:08:00.000Z","message":{"id":"m1","usage":{"input_tokens":100,"output_tokens":10},"content":[{"type":"text","text":"Hi
        """)
        let events = adapter.events(for: root)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].detail, "Hello")
        XCTAssertNil(adapter.usage(for: root))          // the only usage line was truncated
        XCTAssertNotNil(adapter.summary(for: root))
    }

    // Garbage lines interleaved with valid ones: every valid line survives.
    func testInvalidJSONLinesMixedWithValidAreSkipped() throws {
        try write("""
        not json at all
        {"type":"user","message":{"content":"first"}}
        {"broken": [1, 2
        [1,2,3]
        "just a string"
        42
        null
        {"type":"assistant","message":{"id":"m1","model":"claude-sonnet-4","usage":{"input_tokens":1000,"output_tokens":20},"content":[{"type":"text","text":"ok"}]}}
        {}
        {"type":"assistant","message":"not-a-dict"}
        {"type":"user","message":{"content":"second"}}
        """)
        let events = adapter.events(for: root)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].detail, "first")
        XCTAssertEqual(events[1].detail, "ok")
        XCTAssertEqual(events[2].detail, "second")

        let u = try XCTUnwrap(adapter.usage(for: root))
        XCTAssertEqual(u.outputTokens, 20)
    }

    // A pathological single line (megabytes, no newline) must parse without crashing.
    func testHugeSingleLine() throws {
        let big = String(repeating: "x", count: 2_000_000)
        try write("""
        {"type":"assistant","message":{"id":"m1","usage":{"input_tokens":10,"output_tokens":5},"content":[{"type":"text","text":"\(big)"}]}}
        """)
        let events = adapter.events(for: root)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].detail.count, 161)     // truncated to 160 + ellipsis
        XCTAssertNotNil(adapter.usage(for: root))
    }

    // Tool names the adapter has never heard of stay plain .toolUse events.
    func testUnknownToolNames() throws {
        try write("""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"FrobnicateWidget","input":{"file_path":"/proj/A.swift"}},{"type":"tool_use","input":{"command":"ls"}},{"type":"tool_use","name":"Mystery","input":{}}]}}
        """)
        let events = adapter.events(for: root)
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].kind, .toolUse)        // unknown ≠ file edit, even with file_path
        XCTAssertEqual(events[0].title, "FrobnicateWidget")
        XCTAssertEqual(events[0].filePath, "/proj/A.swift")
        XCTAssertEqual(events[1].title, "tool")         // missing name falls back
        XCTAssertEqual(events[2].detail, "")            // empty input → empty detail

        // Unknown tools never count as edits in the summary either.
        XCTAssertEqual(adapter.summary(for: root)?.editedFiles, [])
    }

    // Absent or unparseable timestamps must render as empty, not crash.
    func testAbsentAndMalformedTimestamps() throws {
        try write("""
        {"type":"user","message":{"content":"no timestamp"}}
        {"type":"user","timestamp":"yesterday-ish","message":{"content":"bad timestamp"}}
        {"type":"user","timestamp":"2026-07-09T10:07:12Z","message":{"content":"whole-second timestamp"}}
        {"type":"user","timestamp":"garbageT10:33:44","message":{"content":"unparseable but has T"}}
        """)
        let events = adapter.events(for: root)
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0].timestamp, "")
        XCTAssertEqual(events[1].timestamp, "")
        XCTAssertEqual(events[2].timestamp, localHHMM("2026-07-09T10:07:12.000Z"))
        XCTAssertEqual(events[3].timestamp, "10:33")    // raw UTC HH:MM fallback slice
    }

    // Malformed content shapes: wrong types anywhere in the tree are skipped.
    func testMalformedContentShapes() throws {
        try write("""
        {"type":"user","message":{"content":12345}}
        {"type":"user","message":{"content":["bare-string-not-a-block"]}}
        {"type":"assistant","message":{"content":"assistant-content-as-string"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":42},{"type":"text"},{"type":"tool_use","name":"Bash","input":"not-a-dict"},{"no_type":true}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"   "}]}}
        """)
        let events = adapter.events(for: root)
        // Only the Bash tool_use survives (name valid; its non-dict input → empty detail).
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .toolUse)
        XCTAssertEqual(events[0].title, "Bash")
        XCTAssertEqual(events[0].detail, "")
    }

    // MARK: - Plan vs actual

    func testSummaryCollectsEditsAndTodos() {
        let summary = adapter.summary(for: root)
        XCTAssertNotNil(summary)
        guard let s = summary else { return }

        XCTAssertEqual(s.editedFiles, ["/Users/foo/proj/Sources/App.swift"])

        XCTAssertEqual(s.todos.count, 2)
        XCTAssertEqual(s.todos[0].text, "Write tests")
        XCTAssertEqual(s.todos[0].status, "in_progress")
        XCTAssertEqual(s.todos[1].text, "Ship it")
        XCTAssertEqual(s.todos[1].status, "pending")
    }

    // Todos with missing/mistyped fields: content is required, status defaults.
    func testSummaryWithMalformedTodos() throws {
        try write("""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Good"},{"status":"pending"},{"content":42},"bare-string"]}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":"not-an-array"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"no_file_path":true}}]}}
        """)
        let s = try XCTUnwrap(adapter.summary(for: root))
        XCTAssertEqual(s.todos.count, 1)
        XCTAssertEqual(s.todos[0].text, "Good")
        XCTAssertEqual(s.todos[0].status, "pending")    // missing status defaults
        XCTAssertTrue(s.editedFiles.isEmpty)            // Edit without a path records nothing
    }
}
