//
//  AgentsResolveTests.swift
//  AgentSessionTests
//
//  `Agents.resolve(candidates:)` — the first candidate with a session wins, in
//  the caller's order. The case behind it: Claude launched from a terminal whose
//  cwd was a subfolder, so the transcript was keyed under that subfolder and a
//  lookup of the opened folder alone found "No Agent Session".
//

import XCTest
@testable import AgentSession

final class AgentsResolveTests: XCTestCase {

    private var projectsRoot: URL!
    private let opened = URL(fileURLWithPath: "/private/tmp/agents-resolve-tests/site")
    private let terminalCwd = URL(fileURLWithPath: "/private/tmp/agents-resolve-tests/site/wp-admin/css/colors/coffee")

    override func setUpWithError() throws {
        projectsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-resolve-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    /// The `<projectsRoot>/<encoded cwd>` directory Claude Code would use for `root`.
    private func projectDir(_ root: URL) -> URL {
        let encoded = String(root.path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        return projectsRoot.appendingPathComponent(encoded, isDirectory: true)
    }

    private func recordSession(for root: URL) throws {
        try FileManager.default.createDirectory(at: projectDir(root), withIntermediateDirectories: true)
        try "{\"type\":\"user\",\"timestamp\":\"2026-09-02T10:00:00.000Z\",\"message\":{\"content\":\"hi\"}}\n"
            .write(to: projectDir(root).appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
    }

    func testResolvePicksTheFirstCandidateWithASession() throws {
        try recordSession(for: terminalCwd)
        let adapters: [AgentAdapter] = [ClaudeCodeAdapter(projectsRoot: projectsRoot)]

        XCTAssertNil(Agents.active(for: opened, in: adapters), "the opened folder alone has no session")
        let hit = try XCTUnwrap(Agents.resolve(candidates: [terminalCwd, opened], in: adapters))
        XCTAssertEqual(hit.root, terminalCwd, "the terminal's cwd is where the transcript lives")
        XCTAssertEqual(Agents.resolve(candidates: [opened, terminalCwd], in: adapters)?.root, terminalCwd,
                       "a candidate without a session is skipped, whatever its position")
        XCTAssertNil(Agents.resolve(candidates: [], in: adapters))
        XCTAssertNil(Agents.resolve(candidates: [opened], in: adapters))
    }

    func testResolveHonoursCandidateOrderWhenSeveralHaveSessions() throws {
        try recordSession(for: terminalCwd)
        try recordSession(for: opened)
        let adapters: [AgentAdapter] = [ClaudeCodeAdapter(projectsRoot: projectsRoot)]
        XCTAssertEqual(Agents.resolve(candidates: [terminalCwd, opened], in: adapters)?.root, terminalCwd)
        XCTAssertEqual(Agents.resolve(candidates: [opened, terminalCwd], in: adapters)?.root, opened)
    }
}
