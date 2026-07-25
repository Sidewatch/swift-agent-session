//
//  OpenCodeAdapterTests.swift
//  Tests for SwiftAgentSession
//
//  OpenCode stores a session as a DIRECTORY tree, not a transcript file, so these also pin the
//  widened `events(fromSession:)` seam.
//
//  Created by David Sherlock on 7/26/26.
//

import XCTest
@testable import AgentSession

final class OpenCodeAdapterTests: XCTestCase {

    private var scratch: [URL] = []

    override func tearDownWithError() throws {
        for url in scratch { try? FileManager.default.removeItem(at: url) }
        scratch.removeAll()
    }

    /// Builds a storage tree matching OpenCode's layout and returns its `storage` root.
    ///
    /// `messages` is `(messageID, role, [partJSON])`.
    private func storage(projectPath: String = "/tmp/proj",
                         sessionID: String = "ses_1",
                         messages: [(String, String, [String])]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("opencode-test-\(UUID().uuidString)", isDirectory: true)
        scratch.append(base)
        let storage = base.appendingPathComponent("storage", isDirectory: true)
        let fm = FileManager.default

        func write(_ json: String, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try json.write(to: url, atomically: true, encoding: .utf8)
        }

        try write(#"{"id":"prj_1","worktree":"\#(projectPath)"}"#,
                  to: storage.appendingPathComponent("project/prj_1.json"))
        try write(#"{"id":"\#(sessionID)","title":"demo"}"#,
                  to: storage.appendingPathComponent("session/prj_1/\(sessionID).json"))

        for (index, (messageID, role, parts)) in messages.enumerated() {
            let created = 1_785_000_000_000 + (index * 1000)
            try write(#"{"id":"\#(messageID)","role":"\#(role)","time":{"created":\#(created)}}"#,
                      to: storage.appendingPathComponent("message/\(sessionID)/\(messageID).json"))
            for (partIndex, part) in parts.enumerated() {
                try write(part, to: storage.appendingPathComponent(
                    "part/\(messageID)/prt_\(String(format: "%03d", partIndex)).json"))
            }
        }
        return storage
    }

    private let conversation: [(String, String, [String])] = [
        ("msg_001", "user", [#"{"type":"text","text":"Add a retry to the uploader"}"#]),
        ("msg_002", "assistant", [
            #"{"type":"step-start"}"#,
            #"{"type":"text","text":"Adding exponential backoff."}"#,
            #"{"type":"tool","tool":"read","state":{"status":"completed","input":{"filePath":"Uploader.swift"}}}"#,
            #"{"type":"tool","tool":"edit","state":{"status":"completed","input":{"filePath":"Sources/Uploader.swift"}}}"#,
            #"{"type":"reasoning","text":"thinking"}"#,
        ]),
        ("msg_003", "user", [#"{"type":"text","text":"Cap it at 30 seconds"}"#]),
    ]

    // MARK: - Parsing a directory-shaped session

    func testParsesASessionDirectory() throws {
        let storage = try storage(messages: conversation)
        let adapter = OpenCodeAdapter(storageRoot: storage)
        let events = adapter.events(fromSession: storage.appendingPathComponent("message/ses_1"))

        XCTAssertEqual(events.map(\.kind), [.userPrompt, .assistantText, .toolUse, .fileEdit, .userPrompt])
        XCTAssertEqual(events[0].detail, "Add a retry to the uploader")
        XCTAssertEqual(events[1].title, "OpenCode")
        // `read` is a tool call, `edit` is a file edit — the review surface keys off that split.
        XCTAssertEqual(events[2].title, "read")
        XCTAssertNil(events[2].filePath)
        XCTAssertEqual(events[3].filePath, "Sources/Uploader.swift")
    }

    func testMessageAndPartOrderFollowsIDs() throws {
        let storage = try storage(messages: conversation)
        let events = OpenCodeAdapter(storageRoot: storage)
            .events(fromSession: storage.appendingPathComponent("message/ses_1"))
        // Parts are separate files; conversation order must survive being reassembled from two
        // directory trees.
        XCTAssertEqual(events.first?.detail, "Add a retry to the uploader")
        XCTAssertEqual(events.last?.detail, "Cap it at 30 seconds")
    }

    func testReasoningAndStepStartProduceNoRows() throws {
        let storage = try storage(messages: [
            ("msg_001", "assistant", [#"{"type":"step-start"}"#, #"{"type":"reasoning","text":"x"}"#]),
        ])
        XCTAssertTrue(OpenCodeAdapter(storageRoot: storage)
            .events(fromSession: storage.appendingPathComponent("message/ses_1")).isEmpty)
    }

    func testMessageWithNoPartsDirectoryIsSkipped() throws {
        // A message written before its parts must not abort the whole parse.
        let storage = try storage(messages: [("msg_001", "user", [])])
        XCTAssertTrue(OpenCodeAdapter(storageRoot: storage)
            .events(fromSession: storage.appendingPathComponent("message/ses_1")).isEmpty)
    }

    func testMalformedJSONIsSkipped() throws {
        let storage = try storage(messages: [
            ("msg_001", "user", ["not json", #"{"type":"text","text":"survives"}"#]),
        ])
        let events = OpenCodeAdapter(storageRoot: storage)
            .events(fromSession: storage.appendingPathComponent("message/ses_1"))
        XCTAssertEqual(events.map(\.detail), ["survives"])
    }

    func testMissingDirectoryYieldsNoEvents() {
        let adapter = OpenCodeAdapter(storageRoot: URL(fileURLWithPath: "/nope/\(UUID().uuidString)"))
        XCTAssertTrue(adapter.events(fromSession: URL(fileURLWithPath: "/nope/message/x")).isEmpty)
    }

    func testTimestampsComeFromEpochMilliseconds() throws {
        // OpenCode records ms, not seconds — reading it as seconds dates every row to 1970.
        let storage = try storage(messages: conversation)
        let events = OpenCodeAdapter(storageRoot: storage)
            .events(fromSession: storage.appendingPathComponent("message/ses_1"))
        let stamp = try XCTUnwrap(events.first?.timestamp)
        XCTAssertEqual(stamp.count, 5)              // HH:mm
        XCTAssertFalse(stamp.hasPrefix("00:0"))     // 1970-ish would land here
    }

    // MARK: - Locating a session

    func testFindsTheSessionForThisProject() throws {
        let storage = try storage(projectPath: "/tmp/my-project", messages: conversation)
        let adapter = OpenCodeAdapter(storageRoot: storage)
        XCTAssertTrue(adapter.hasSession(for: URL(fileURLWithPath: "/tmp/my-project")))
        XCTAssertEqual(adapter.events(for: URL(fileURLWithPath: "/tmp/my-project")).count, 5)
    }

    func testIgnoresAnotherProjectsSessions() throws {
        let storage = try storage(projectPath: "/tmp/elsewhere", messages: conversation)
        let adapter = OpenCodeAdapter(storageRoot: storage)
        XCTAssertFalse(adapter.hasSession(for: URL(fileURLWithPath: "/tmp/my-project")))
        XCTAssertTrue(adapter.events(for: URL(fileURLWithPath: "/tmp/my-project")).isEmpty)
    }

    func testSummaryReportsEditedFilesOnly() throws {
        let storage = try storage(projectPath: "/tmp/my-project", messages: conversation)
        let summary = OpenCodeAdapter(storageRoot: storage).summary(for: URL(fileURLWithPath: "/tmp/my-project"))
        XCTAssertEqual(summary?.editedFiles, ["Sources/Uploader.swift"])
    }

    // MARK: - Usage

    func testUsageSumsCostAndOutputButTakesLatestContext() throws {
        let storage = try storage(projectPath: "/tmp/usage", messages: conversation)
        // Rewrite the assistant message with token metadata, in the nested shape OpenCode uses.
        let file = storage.appendingPathComponent("message/ses_1/msg_002.json")
        try #"""
        {"id":"msg_002","role":"assistant","time":{"created":1785000005000},
         "metadata":{"assistant":{"cost":0.0125,
           "tokens":{"input":900,"output":250,"reasoning":10,"cache":{"read":100,"write":0}}}}}
        """#.write(to: file, atomically: true, encoding: .utf8)

        let usage = try XCTUnwrap(OpenCodeAdapter(storageRoot: storage)
            .usage(for: URL(fileURLWithPath: "/tmp/usage")))
        XCTAssertEqual(usage.contextTokens, 1260)   // 900 + 100 read + 250 out + 10 reasoning
        XCTAssertEqual(usage.outputTokens, 250)
        XCTAssertEqual(usage.costUSD, 0.0125, accuracy: 0.0001)  // recorded, not estimated
        XCTAssertEqual(usage.contextLimit, 0)       // window unknown → percent reports 0
    }

    func testNoTokenMetadataMeansNoUsage() throws {
        let storage = try storage(projectPath: "/tmp/usage", messages: conversation)
        XCTAssertNil(OpenCodeAdapter(storageRoot: storage).usage(for: URL(fileURLWithPath: "/tmp/usage")))
    }

    func testTokensAreFoundAtEitherNesting() {
        XCTAssertNotNil(OpenCodeAdapter.tokens(in: ["tokens": ["input": 1.0]]))
        XCTAssertNotNil(OpenCodeAdapter.tokens(in: ["metadata": ["assistant": ["tokens": ["input": 1.0]]]]))
        XCTAssertNil(OpenCodeAdapter.tokens(in: ["role": "user"]))
    }

    // MARK: - Edit detection

    func testOnlyWritingToolsCountAsEdits() {
        // Reporting a read as an edit would put files in the review surface the agent never
        // touched — the one mistake this classification must not make.
        XCTAssertNil(OpenCodeAdapter.editedPath(tool: "read", input: ["filePath": "a.swift"]))
        XCTAssertNil(OpenCodeAdapter.editedPath(tool: "bash", input: ["command": "ls"]))
        XCTAssertEqual(OpenCodeAdapter.editedPath(tool: "edit", input: ["filePath": "a.swift"]), "a.swift")
        XCTAssertEqual(OpenCodeAdapter.editedPath(tool: "Write", input: ["file_path": "b.swift"]), "b.swift")
    }

    // MARK: - Shapes confirmed against OpenCode's source

    func testToolArgumentsComeFromStateInputAtEveryStatus() throws {
        // Verified in message-v2.ts: a tool part is {type:"tool", tool, callID, state:{status,
        // input, …}} and `state.input` is present for pending/running/completed/error alike, so
        // a still-running edit must not lose its path.
        let storage = try storage(messages: [
            ("msg_001", "assistant", [
                #"{"type":"tool","tool":"edit","callID":"c1","state":{"status":"running","input":{"filePath":"A.swift"}}}"#,
                #"{"type":"tool","tool":"edit","callID":"c2","state":{"status":"completed","input":{"filePath":"B.swift"},"output":"ok"}}"#,
                #"{"type":"tool","tool":"bash","callID":"c3","state":{"status":"error","input":{"command":"false"},"error":"exit 1"}}"#,
            ]),
        ])
        let events = OpenCodeAdapter(storageRoot: storage)
            .events(fromSession: storage.appendingPathComponent("message/ses_1"))
        XCTAssertEqual(events.map(\.filePath), ["A.swift", "B.swift", nil])
        XCTAssertEqual(events[2].detail, "false")
    }

    func testProjectRecordIsMatchedByAnyPathValue() throws {
        // The record is {id, worktree} today; matching any string value that resolves to the root
        // keeps this working if that field is renamed, which it already has been once.
        let storage = try storage(projectPath: "/tmp/renamed-field", messages: conversation)
        let file = storage.appendingPathComponent("project/prj_1.json")
        try #"{"id":"prj_1","directory":"/tmp/renamed-field"}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(OpenCodeAdapter(storageRoot: storage)
            .hasSession(for: URL(fileURLWithPath: "/tmp/renamed-field")))
    }

    // MARK: - Cross-dialect safety

    func testDeclinesOtherAgentsFormats() throws {
        // A JSONL transcript is a FILE; this adapter must return nothing rather than throw or
        // half-parse, or `Agents.active` would pick whichever adapter ran first.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oc-foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.append(dir)
        let file = dir.appendingPathComponent("session.jsonl")
        try #"{"type":"user","message":{"content":"hi"}}"#.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(OpenCodeAdapter().events(fromSession: file).isEmpty)
    }

    func testOtherAdaptersDeclineASessionDirectory() throws {
        let storage = try storage(messages: conversation)
        let dir = storage.appendingPathComponent("message/ses_1")
        // Claude and Codex read files; handed a directory they must yield nothing, not crash.
        XCTAssertTrue(ClaudeCodeAdapter().events(fromSession: dir).isEmpty)
        XCTAssertTrue(CodexAdapter().events(fromSession: dir).isEmpty)
    }

    func testRegisteredInTheAdapterList() {
        XCTAssertTrue(Agents.all.contains { $0.name == "OpenCode" })
    }
}
