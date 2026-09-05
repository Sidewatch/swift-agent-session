//
//  GeminiAdapterTests.swift
//  Tests for SwiftAgentSession
//
//  Gemini stores chats in TWO file shapes and locates projects by an opaque id, so these pin
//  both readers and the `.project_root` marker strategy.
//
//  Created by David Sherlock on 7/26/26.
//

import XCTest
@testable import AgentSession

/// Tests for `GeminiAdapter` against both chat file shapes and the opaque project id it locates
/// projects by.
final class GeminiAdapterTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
    }

    /// Builds `~/.gemini/tmp` with one project directory, and returns the temp root.
    private func tempRoot(projectPath: String = "/tmp/proj",
                          projectID: String = "my-project",
                          chats: [(name: String, body: String)]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("gemini-test-\(UUID().uuidString)", isDirectory: true)
        scratch.append(base)
        let project = base.appendingPathComponent(projectID, isDirectory: true)
        let chatsDir = project.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        try projectPath.write(to: project.appendingPathComponent(".project_root"),
                              atomically: true, encoding: .utf8)
        for chat in chats {
            try chat.body.write(to: chatsDir.appendingPathComponent(chat.name),
                                atomically: true, encoding: .utf8)
        }
        return base
    }

    /// A whole `ConversationRecord`, the `.json` shape.
    private let wholeRecord = """
    {"sessionId":"s1","projectHash":"abc","startTime":"2026-07-26T10:00:00.000Z",
     "lastUpdated":"2026-07-26T10:05:00.000Z","messages":[
      {"id":"m1","timestamp":"2026-07-26T10:00:01.000Z","type":"user","content":"Add a retry to the uploader"},
      {"id":"m2","timestamp":"2026-07-26T10:00:04.000Z","type":"gemini",
       "content":[{"text":"Adding exponential backoff."}],
       "toolCalls":[
         {"id":"t1","name":"read_file","args":{"file_path":"Uploader.swift"},"status":"success","timestamp":"2026-07-26T10:00:05.000Z"},
         {"id":"t2","name":"replace","args":{"file_path":"Sources/Uploader.swift"},"status":"success","timestamp":"2026-07-26T10:00:06.000Z"}]},
      {"id":"m3","timestamp":"2026-07-26T10:00:07.000Z","type":"info","content":"context left: 80%"},
      {"id":"m4","timestamp":"2026-07-26T10:05:00.000Z","type":"user","content":[{"text":"Cap it at 30 seconds"}]}
     ]}
    """

    /// The `.jsonl` shape: a metadata line, then one record per line.
    private let jsonlRecord = """
    {"sessionId":"s2","projectHash":"abc","startTime":"2026-07-26T11:00:00.000Z"}
    {"id":"m1","timestamp":"2026-07-26T11:00:01.000Z","type":"user","content":"Rename the module"}
    {"id":"m2","timestamp":"2026-07-26T11:00:03.000Z","type":"gemini","content":{"text":"Renaming."},"toolCalls":[{"id":"t1","name":"write_file","args":{"file_path":"New.swift"},"status":"success","timestamp":"2026-07-26T11:00:04.000Z"}]}
    """

    // MARK: - Both file shapes

    func testParsesAWholeConversationRecord() throws {
        let root = try tempRoot(chats: [("session-s1.json", wholeRecord)])
        let file = root.appendingPathComponent("my-project/chats/session-s1.json")
        let events = GeminiAdapter(tempRoot: root).events(fromSession: file)

        XCTAssertEqual(events.map(\.kind), [.userPrompt, .assistantText, .toolUse, .fileEdit, .userPrompt])
        XCTAssertEqual(events[0].detail, "Add a retry to the uploader")
        XCTAssertEqual(events[1].title, "Gemini")
        // read_file is a tool call; `replace` is Gemini's edit tool.
        XCTAssertEqual(events[2].title, "read_file")
        XCTAssertNil(events[2].filePath)
        XCTAssertEqual(events[3].filePath, "Sources/Uploader.swift")
    }

    func testParsesTheJSONLShapeAndSkipsTheMetadataLine() throws {
        let root = try tempRoot(chats: [("session-s2.jsonl", jsonlRecord)])
        let file = root.appendingPathComponent("my-project/chats/session-s2.jsonl")
        let events = GeminiAdapter(tempRoot: root).events(fromSession: file)

        // The leading {sessionId,…} record has no `type` and must not become a row.
        XCTAssertEqual(events.map(\.kind), [.userPrompt, .assistantText, .fileEdit])
        XCTAssertEqual(events[2].filePath, "New.swift")
    }

    func testInfoErrorWarningRecordsAreNotConversation() throws {
        let root = try tempRoot(chats: [("s.json", wholeRecord)])
        let events = GeminiAdapter(tempRoot: root)
            .events(fromSession: root.appendingPathComponent("my-project/chats/s.json"))
        XCTAssertFalse(events.contains { $0.detail.contains("context left") })
    }

    // MARK: - PartListUnion

    func testContentAcceptsStringSinglePartAndArray() {
        // All three shapes appear in stored records; assuming one silently loses messages.
        XCTAssertEqual(GeminiAdapter.partsText("plain"), "plain")
        XCTAssertEqual(GeminiAdapter.partsText(["text": "single"]), "single")
        XCTAssertEqual(GeminiAdapter.partsText([["text": "a"], ["text": "b"]]), "a b")
        XCTAssertEqual(GeminiAdapter.partsText(nil), "")
        XCTAssertEqual(GeminiAdapter.partsText([["inlineData": "x"]]), "")
    }

    // MARK: - Ignored user content (ported from gemini-cli's own rule)

    func testMachineryIsNotAPrompt() {
        // Verified against gemini-cli's isIgnoredUserContent and the cases its tests assert on.
        XCTAssertTrue(GeminiAdapter.isIgnoredUserContent("/resume"))
        XCTAssertTrue(GeminiAdapter.isIgnoredUserContent("?help"))
        XCTAssertTrue(GeminiAdapter.isIgnoredUserContent("<session_context>previous state</session_context>"))
        XCTAssertTrue(GeminiAdapter.isIgnoredUserContent("<hook_context>hook data</hook_context>"))
        XCTAssertTrue(GeminiAdapter.isIgnoredUserContent("   "))
        XCTAssertFalse(GeminiAdapter.isIgnoredUserContent("Add a retry"))
    }

    func testInjectedRecordsDoNotOpenSpuriousTurns() throws {
        // The real cost of getting this wrong: each machinery record would start a new turn, so
        // checkpoints and turn diffs would be cut at boundaries the human never created.
        let record = """
        {"sessionId":"s","projectHash":"a","startTime":"2026-07-26T10:00:00.000Z","messages":[
         {"id":"m1","timestamp":"2026-07-26T10:00:00.000Z","type":"user","content":"<session_context>state</session_context>"},
         {"id":"m2","timestamp":"2026-07-26T10:00:01.000Z","type":"user","content":"/resume"},
         {"id":"m3","timestamp":"2026-07-26T10:00:02.000Z","type":"user","content":"Add a retry"},
         {"id":"m4","timestamp":"2026-07-26T10:00:03.000Z","type":"gemini","content":"Done."}
        ]}
        """
        let root = try tempRoot(chats: [("s.json", record)])
        let events = GeminiAdapter(tempRoot: root)
            .events(fromSession: root.appendingPathComponent("my-project/chats/s.json"))
        XCTAssertEqual(events.map(\.kind), [.userPrompt, .assistantText])
        XCTAssertEqual(events[0].detail, "Add a retry")
        XCTAssertEqual(TurnBoundary.turns(in: events).count, 1)
    }

    func testMixedPartArrayWithRawStringsStillYieldsText() {
        // PartListUnion arrays may hold raw strings alongside {text} parts. Casting the array to
        // [[String: Any]] failed outright on the first raw string, blanking the whole message —
        // and for a user record that silently deletes a turn boundary.
        XCTAssertEqual(GeminiAdapter.partsText(["raw", ["text": "part"]]), "raw part")
        XCTAssertEqual(GeminiAdapter.partsText(["only raw"]), "only raw")
    }

    // MARK: - Edit detection

    func testOnlyWritingToolsCountAsEdits() {
        XCTAssertEqual(GeminiAdapter.editedPath(tool: "replace", args: ["file_path": "a.swift"]), "a.swift")
        XCTAssertEqual(GeminiAdapter.editedPath(tool: "write_file", args: ["file_path": "b.swift"]), "b.swift")
        // Reading a file is not editing it.
        XCTAssertNil(GeminiAdapter.editedPath(tool: "read_file", args: ["file_path": "a.swift"]))
        XCTAssertNil(GeminiAdapter.editedPath(tool: "run_shell_command", args: ["command": "ls"]))
    }

    // MARK: - Usage

    func testUsageFromTokenSummaries() throws {
        let record = """
        {"sessionId":"s","projectHash":"a","startTime":"2026-07-26T10:00:00.000Z","messages":[
         {"id":"m1","timestamp":"2026-07-26T10:00:00.000Z","type":"user","content":"go"},
         {"id":"m2","timestamp":"2026-07-26T10:00:01.000Z","type":"gemini","content":"one",
          "tokens":{"input":500,"output":100,"cached":0,"total":600}},
         {"id":"m3","timestamp":"2026-07-26T10:00:02.000Z","type":"gemini","content":"two",
          "tokens":{"input":900,"output":150,"cached":100,"total":1150}}
        ]}
        """
        let root = try tempRoot(projectPath: "/tmp/usage", chats: [("s.json", record)])
        let usage = try XCTUnwrap(GeminiAdapter(tempRoot: root).usage(for: URL(fileURLWithPath: "/tmp/usage")))
        XCTAssertEqual(usage.contextTokens, 1150)   // latest exchange = the window fill
        XCTAssertEqual(usage.outputTokens, 250)     // summed across the session
        XCTAssertEqual(usage.contextLimit, 0)       // Gemini does not record the window
    }

    func testNoTokenSummariesMeansNoUsage() throws {
        let root = try tempRoot(projectPath: "/tmp/usage", chats: [("s.json", wholeRecord)])
        XCTAssertNil(GeminiAdapter(tempRoot: root).usage(for: URL(fileURLWithPath: "/tmp/usage")))
    }

    // MARK: - Locating by .project_root marker

    func testFindsTheProjectByItsMarker() throws {
        let root = try tempRoot(projectPath: "/tmp/my-project", chats: [("s.json", wholeRecord)])
        let adapter = GeminiAdapter(tempRoot: root)
        XCTAssertTrue(adapter.hasSession(for: URL(fileURLWithPath: "/tmp/my-project")))
        XCTAssertEqual(adapter.events(for: URL(fileURLWithPath: "/tmp/my-project")).count, 5)
    }

    func testWorksForALegacyHashDirectoryToo() throws {
        // Older installs name the directory with a sha256 of the path rather than a slug. The
        // marker is what makes both work without reproducing either scheme.
        let hash = String(repeating: "a", count: 64)
        let root = try tempRoot(projectPath: "/tmp/legacy", projectID: hash, chats: [("s.json", wholeRecord)])
        XCTAssertTrue(GeminiAdapter(tempRoot: root).hasSession(for: URL(fileURLWithPath: "/tmp/legacy")))
    }

    func testIgnoresAnotherProjectsDirectory() throws {
        let root = try tempRoot(projectPath: "/tmp/elsewhere", chats: [("s.json", wholeRecord)])
        let adapter = GeminiAdapter(tempRoot: root)
        XCTAssertFalse(adapter.hasSession(for: URL(fileURLWithPath: "/tmp/my-project")))
        XCTAssertTrue(adapter.events(for: URL(fileURLWithPath: "/tmp/my-project")).isEmpty)
    }

    func testDirectoryWithNoMarkerIsSkippedNotFatal() throws {
        let root = try tempRoot(chats: [("s.json", wholeRecord)])
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("orphan/chats", isDirectory: true),
            withIntermediateDirectories: true)
        XCTAssertTrue(GeminiAdapter(tempRoot: root).hasSession(for: URL(fileURLWithPath: "/tmp/proj")))
    }

    func testMissingTempRootYieldsNothing() {
        let adapter = GeminiAdapter(tempRoot: URL(fileURLWithPath: "/nope/\(UUID().uuidString)"))
        XCTAssertFalse(adapter.hasSession(for: URL(fileURLWithPath: "/tmp/x")))
        XCTAssertTrue(adapter.events(for: URL(fileURLWithPath: "/tmp/x")).isEmpty)
    }

    // MARK: - Cross-dialect safety

    func testDeclinesOtherAgentsFormats() throws {
        let root = try tempRoot(chats: [
            ("claude.jsonl", #"{"type":"user","message":{"content":"hi"}}"#),
            ("codex.jsonl", #"{"timestamp":"2026-07-26T10:00:00.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"hi"}]}}"#),
        ])
        let adapter = GeminiAdapter(tempRoot: root)
        XCTAssertTrue(adapter.events(fromSession: root.appendingPathComponent("my-project/chats/claude.jsonl")).isEmpty)
        // Codex lines DO carry a "type", so this is the case most likely to half-parse.
        XCTAssertTrue(adapter.events(fromSession: root.appendingPathComponent("my-project/chats/codex.jsonl")).isEmpty)
    }

    func testOtherAdaptersDeclineAGeminiChat() throws {
        let root = try tempRoot(chats: [("s.json", wholeRecord)])
        let file = root.appendingPathComponent("my-project/chats/s.json")
        XCTAssertTrue(ClaudeCodeAdapter().events(fromSession: file).isEmpty)
        XCTAssertTrue(CodexAdapter().events(fromSession: file).isEmpty)
        XCTAssertTrue(OpenCodeAdapter().events(fromSession: file).isEmpty)
    }

    func testRegisteredInTheAdapterList() {
        XCTAssertTrue(Agents.all.contains { $0.name == "Gemini CLI" })
    }
}
