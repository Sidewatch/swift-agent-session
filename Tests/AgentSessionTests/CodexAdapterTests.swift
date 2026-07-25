//
//  CodexAdapterTests.swift
//  Tests for SwiftAgentSession
//
//  Exercises the Codex dialect against fixtures built from the published schema
//  (codex-rs/protocol/src/protocol.rs — `#[serde(tag = "type", content = "payload")]`).
//
//  Created by David Sherlock on 7/26/26.
//

import XCTest
@testable import AgentSession

final class CodexAdapterTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
    }

    /// Writes a rollout at `sessions/2026/07/26/rollout-….jsonl`, mirroring Codex's real layout.
    @discardableResult
    private func rollout(_ lines: [String], cwd: String? = nil, day: String = "26",
                         id: String = "aaaa") throws -> (sessions: URL, file: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-test-\(UUID().uuidString)", isDirectory: true)
        scratch.append(base)
        let sessions = base.appendingPathComponent("sessions/2026/07/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        var body = lines
        if let cwd {
            body.insert(#"{"timestamp":"2026-07-26T10:00:00Z","type":"turn_context","payload":{"cwd":"\#(cwd)"}}"#,
                        at: 0)
        }
        let file = sessions.appendingPathComponent("rollout-2026-07-\(day)T10-00-00-\(id).jsonl")
        try body.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return (base.appendingPathComponent("sessions", isDirectory: true), file)
    }

    /// Lines shaped exactly as Codex serialises them, verified against codex-rs source:
    /// `RolloutLine { timestamp, ordinal?, #[serde(flatten)] item }` with
    /// `RolloutItem #[serde(tag = "type", content = "payload")]`; timestamps are
    /// `[year]-[month]-[day]T[hour]:[minute]:[second].[subsecond digits:3]Z`; `LocalShellAction`
    /// is ITSELF internally tagged, so `action` carries `"type":"exec"` beside its fields.
    private let conversation = [
        #"{"timestamp":"2026-07-26T10:00:01.000Z","ordinal":1,"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Add a retry to the uploader"}]}}"#,
        #"{"timestamp":"2026-07-26T10:00:04.100Z","ordinal":2,"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Adding exponential backoff."}]}}"#,
        #"{"timestamp":"2026-07-26T10:00:07.200Z","ordinal":3,"type":"response_item","payload":{"type":"local_shell_call","call_id":"c0","status":"completed","action":{"type":"exec","command":["cat","Uploader.swift"],"timeout_ms":null,"working_directory":null}}}"#,
        #"{"timestamp":"2026-07-26T10:00:09.300Z","ordinal":4,"type":"response_item","payload":{"type":"function_call","name":"apply_patch","call_id":"c1","arguments":"{\"input\":\"*** Update File: Sources/Uploader.swift\\n@@\\n+retry()\"}"}}"#,
        #"{"timestamp":"2026-07-26T10:00:12.400Z","ordinal":5,"type":"response_item","payload":{"type":"reasoning","summary":["thinking"]}}"#,
    ]

    // MARK: - Parsing

    func testParsesTheCodexDialect() throws {
        let (_, file) = try rollout(conversation)
        let events = CodexAdapter().events(fromSession: file)

        XCTAssertEqual(events.map(\.kind), [.userPrompt, .assistantText, .toolUse, .fileEdit])
        XCTAssertEqual(events[0].detail, "Add a retry to the uploader")
        XCTAssertEqual(events[1].title, "Codex")
        XCTAssertEqual(events[2].detail, "cat Uploader.swift")
        // apply_patch names its target inside the patch body, not as an argument key.
        XCTAssertEqual(events[3].filePath, "Sources/Uploader.swift")
    }

    func testReasoningAndOutputsProduceNoRows() throws {
        let (_, file) = try rollout([
            #"{"timestamp":"2026-07-26T10:00:00Z","type":"response_item","payload":{"type":"reasoning","summary":["x"]}}"#,
            #"{"timestamp":"2026-07-26T10:00:01Z","type":"response_item","payload":{"type":"function_call_output","call_id":"c1","output":"ok"}}"#,
            #"{"timestamp":"2026-07-26T10:00:02Z","type":"web_search_call","payload":{}}"#,
        ])
        XCTAssertTrue(CodexAdapter().events(fromSession: file).isEmpty)
    }

    func testNonResponseItemLinesAreIgnored() throws {
        // session_meta / turn_context / world_state carry no conversation content.
        let (_, file) = try rollout(conversation, cwd: "/tmp/project")
        XCTAssertEqual(CodexAdapter().events(fromSession: file).count, 4)
    }

    func testMalformedLinesAreSkipped() throws {
        var lines = conversation
        lines.insert("not json", at: 1)
        lines.insert(#"{"type":"response_item"}"#, at: 3)
        let (_, file) = try rollout(lines)
        XCTAssertEqual(CodexAdapter().events(fromSession: file).count, 4)
    }

    func testAClaudeTranscriptYieldsNothingFromTheCodexAdapter() throws {
        // Cross-dialect safety: each adapter must decline the other's format rather than
        // half-parsing it, or `Agents.active` would pick whichever ran first.
        let (_, file) = try rollout([
            #"{"type":"user","timestamp":"2026-07-26T10:00:00Z","message":{"content":"hello"}}"#,
        ])
        XCTAssertTrue(CodexAdapter().events(fromSession: file).isEmpty)
    }

    func testACodexTranscriptYieldsNothingFromTheClaudeAdapter() throws {
        let (_, file) = try rollout(conversation)
        XCTAssertTrue(ClaudeCodeAdapter().events(fromSession: file).isEmpty)
    }

    // MARK: - Locating a session by working directory

    func testFindsTheSessionRecordingThisProject() throws {
        let (sessions, file) = try rollout(conversation, cwd: "/tmp/my-project")
        let adapter = CodexAdapter(sessionsRoot: sessions)
        // Compare resolved paths — the temp dir is reached via the /var → /private/var symlink.
        XCTAssertEqual(adapter.latestSessionFile(for: URL(fileURLWithPath: "/tmp/my-project"))?
            .resolvingSymlinksInPath().path, file.resolvingSymlinksInPath().path)
        XCTAssertTrue(adapter.hasSession(for: URL(fileURLWithPath: "/tmp/my-project")))
    }

    func testIgnoresSessionsRecordedForAnotherProject() throws {
        let (sessions, _) = try rollout(conversation, cwd: "/tmp/somewhere-else")
        let adapter = CodexAdapter(sessionsRoot: sessions)
        XCTAssertNil(adapter.latestSessionFile(for: URL(fileURLWithPath: "/tmp/my-project")))
        XCTAssertFalse(adapter.hasSession(for: URL(fileURLWithPath: "/tmp/my-project")))
    }

    func testNoSessionsDirectoryIsNotAnError() {
        let adapter = CodexAdapter(sessionsRoot: URL(fileURLWithPath: "/nope/\(UUID().uuidString)"))
        XCTAssertFalse(adapter.hasSession(for: URL(fileURLWithPath: "/tmp/x")))
        XCTAssertTrue(adapter.events(for: URL(fileURLWithPath: "/tmp/x")).isEmpty)
    }

    // MARK: - Edit-path extraction

    func testEditedPathFromAJSONArgumentObject() {
        let path = TranscriptState.codexEditedPath(tool: "write_file",
                                                   arguments: #"{"file_path":"a/b.swift","contents":"x"}"#)
        XCTAssertEqual(path, "a/b.swift")
    }

    func testEditedPathFromAnApplyPatchEnvelope() {
        XCTAssertEqual(TranscriptState.codexEditedPath(tool: "apply_patch",
                                                       arguments: "*** Add File: new.txt\n+hi"),
                       "new.txt")
        XCTAssertEqual(TranscriptState.codexEditedPath(tool: "apply_patch",
                                                       arguments: "*** Delete File: gone.txt"),
                       "gone.txt")
    }

    func testCustomToolCallUsesInputNotArguments() throws {
        // Verified against models.rs: CustomToolCall carries `input: String`, while FunctionCall
        // carries `arguments: String`. Reading the wrong key would silently drop every freeform
        // tool call — including apply_patch when Codex sends it that way.
        let (_, file) = try rollout([
            #"{"timestamp":"2026-07-26T10:00:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"c1","name":"apply_patch","input":"*** Add File: fresh.txt\n+hi"}}"#,
        ])
        let events = CodexAdapter().events(fromSession: file)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].kind, .fileEdit)
        XCTAssertEqual(events[0].filePath, "fresh.txt")
    }

    func testTaggedShellActionStillYieldsTheCommand() throws {
        // LocalShellAction is an internally-tagged enum, so `action` has a "type" key beside
        // `command`. Reading `command` must not be confused by it.
        let (_, file) = try rollout([
            #"{"timestamp":"2026-07-26T10:00:00.000Z","type":"response_item","payload":{"type":"local_shell_call","status":"completed","action":{"type":"exec","command":["swift","test"]}}}"#,
        ])
        XCTAssertEqual(CodexAdapter().events(fromSession: file).first?.detail, "swift test")
    }

    func testFractionalTimestampsParse() throws {
        // Codex writes `.[subsecond digits:3]Z`; a parser that only accepted whole seconds
        // would blank every row's time.
        let (_, file) = try rollout(conversation)
        XCTAssertFalse(CodexAdapter().events(fromSession: file).first?.timestamp.isEmpty ?? true)
    }

    func testNonEditToolHasNoPath() {
        // A shell call must not be reported as a file edit — the review surface keys off that.
        XCTAssertNil(TranscriptState.codexEditedPath(tool: "shell", arguments: #"{"command":"ls"}"#))
    }
}
