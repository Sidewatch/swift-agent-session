//
//  PersistedOutputTests.swift
//  AgentSessionTests
//
//  A spilled tool result is read back from its file's tail; anything else is left alone.
//
//  Created by David Sherlock on 9/24/26.
//

import XCTest
@testable import AgentSession

final class PersistedOutputTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("persisted-\(UUID().uuidString)/session/tool-results")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent().deletingLastPathComponent()) }

    func stub(_ path: String) -> String {
        "<persisted-output>\nOutput too large (37.3KB). Full output saved to: \(path)\n\nPreview (first 2KB):\n----\nTest Suite 'All tests' started\n"
    }

    func testAStubIsReplacedByTheFilesTail() throws {
        let file = dir.appendingPathComponent("abc123.txt")
        let body = String(repeating: "Test Case passed\n", count: 2_000) + "Executed 200 tests, with 0 failures\n"
        try body.write(to: file, atomically: true, encoding: .utf8)
        let out = PersistedOutput.resolved(stub(file.path), cap: 6_000)
        XCTAssertTrue(out.hasPrefix("…"), "cut, so marked")
        XCTAssertTrue(out.hasSuffix("Executed 200 tests, with 0 failures\n"), "the END of the output, where the summary is")
        XCTAssertFalse(out.contains("<persisted-output>"))
        XCTAssertEqual(out.count, 6_001)
        let small = dir.appendingPathComponent("small.txt")
        try "short\n".write(to: small, atomically: true, encoding: .utf8)
        XCTAssertEqual(PersistedOutput.resolved(stub(small.path), cap: 6_000), "short\n", "a file under the cap comes whole, no ellipsis")
    }

    func testAMissingFileKeepsTheStubAndOtherTextIsUntouched() {
        let missing = stub(dir.appendingPathComponent("gone.txt").path)
        XCTAssertEqual(PersistedOutput.resolved(missing, cap: 6_000), missing)
        XCTAssertEqual(PersistedOutput.resolved("plain result\n", cap: 6_000), "plain result\n")
        XCTAssertNil(PersistedOutput.savedPath(in: "Full output saved to: /tmp/x.txt"), "the marker must lead")
    }

    func testOnlyAToolResultsFileIsFollowed() {
        var asked: [String] = []
        let elsewhere = "<persisted-output>\nOutput too large (1KB). Full output saved to: /etc/passwd\n\nPreview (first 2KB):\n"
        XCTAssertEqual(PersistedOutput.resolved(elsewhere, cap: 100, read: { asked.append($0); return "secret" }), elsewhere)
        XCTAssertTrue(asked.isEmpty, "a path outside a tool-results folder is never read")
        let inside = dir.appendingPathComponent("ok.txt").path
        XCTAssertEqual(PersistedOutput.resolved(stub(inside), cap: 100, read: { asked.append($0); return "tail" }), "tail")
        XCTAssertEqual(asked, [inside])
    }

    /// Through the transcript parser: a tool call whose result was spilled carries the file's tail.
    func testTheParserFollowsASpilledResult() throws {
        let file = dir.appendingPathComponent("r1.txt")
        try (String(repeating: "x\n", count: 4_000) + "Executed 12 tests, with 1 failure\n").write(to: file, atomically: true, encoding: .utf8)
        let stubJSON = stub(file.path).replacingOccurrences(of: "\n", with: "\\n")
        let lines = [
            #"{"type":"assistant","timestamp":"2026-09-24T10:00:00.000Z","message":{"id":"m1","content":[{"type":"tool_use","id":"tu_1","name":"Bash","input":{"command":"swift test"}}]}}"#,
            "{\"type\":\"user\",\"timestamp\":\"2026-09-24T10:00:05.000Z\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu_1\",\"content\":\"\(stubJSON)\"}]}}",
        ]
        var state = TranscriptState()
        for line in lines { state.ingest(lineData: Data(line.utf8)) }
        let result = try XCTUnwrap(state.eventsResult.first { $0.toolUseID == "tu_1" }?.result)
        XCTAssertTrue(result.hasSuffix("Executed 12 tests, with 1 failure\n"), result.suffix(80).description)
        XCTAssertFalse(result.contains("<persisted-output>"))
    }
}
