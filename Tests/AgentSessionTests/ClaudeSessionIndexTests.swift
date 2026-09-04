import XCTest
@testable import AgentSession

/// Ported from Sidewatch's --dump-terminal-status: the session-id → directory link that makes
/// "Needs you" attributable to a terminal.
final class ClaudeSessionIndexTests: XCTestCase {
    func testEncodeFoldsEveryNonAlphanumericToADash() {
        let cases: [(String, String)] = [
            ("/Users/x/Developer/FSS Migration", "-Users-x-Developer-FSS-Migration"),
            ("/Users/x/.config/nvim", "-Users-x--config-nvim"),
            ("/Users/x/dev/my_project", "-Users-x-dev-my-project"),
        ]
        // Non-ASCII goes through candidateEncodings, never a single literal: Foundation may hand
        // back the decomposed form (`e` + accent → `e-`), and the precomposed one folds to `-`.
        for (path, want) in cases { XCTAssertEqual(ClaudeSessionIndex.encode(URL(fileURLWithPath: path)), want) }
    }

    func testCandidateEncodingsCoverBothUnicodeFormsAndThePrivatePrefix() {
        let accented = ClaudeSessionIndex.candidateEncodings(of: URL(fileURLWithPath: "/Users/x/T\u{EB}st 2.0"))
        XCTAssertTrue(accented.isSuperset(of: ["-Users-x-T-st-2-0", "-Users-x-Te-st-2-0"]), "\(accented)")
        let tmp = ClaudeSessionIndex.candidateEncodings(of: URL(fileURLWithPath: "/tmp/proj"))
        XCTAssertTrue(tmp.contains("-tmp-proj") && tmp.contains("-private-tmp-proj"), "\(tmp)")
    }

    func testResolvesASessionToItsProjectFolderAndCachesTheHit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        let proj = root.appendingPathComponent("-Users-x-dev-app")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "{}".write(to: proj.appendingPathComponent("sess-1.jsonl"), atomically: true, encoding: .utf8)
        let index = ClaudeSessionIndex(projectsRoot: root)
        XCTAssertEqual(index.projectDirectory(forSession: "sess-1"), "-Users-x-dev-app")
        XCTAssertTrue(index.directory(URL(fileURLWithPath: "/Users/x/dev/app"), matchesSession: "sess-1"))
        XCTAssertFalse(index.directory(URL(fileURLWithPath: "/Users/x/dev/other"), matchesSession: "sess-1"))
        XCTAssertNil(index.projectDirectory(forSession: "00000000-dead-beef-0000-000000000000"), "an unknown session resolves to nothing, never something arbitrary")
        try FileManager.default.removeItem(at: proj)
        XCTAssertEqual(index.projectDirectory(forSession: "sess-1"), "-Users-x-dev-app", "cached: sessions do not move")
        index.resetCache()
        XCTAssertNil(index.projectDirectory(forSession: "sess-1"))
    }

    func testTheAdapterUsesTheSameEncoding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cwd = URL(fileURLWithPath: "/Users/x/T\u{EB}st 2.0")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(ClaudeSessionIndex.encode(cwd)), withIntermediateDirectories: true)
        XCTAssertNotNil(ClaudeCodeAdapter(projectsRoot: root).projectDir(for: cwd), "one fold for the package, not two")
    }
}
