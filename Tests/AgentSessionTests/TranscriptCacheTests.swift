//
//  TranscriptCacheTests.swift
//  Tests for the incremental transcript cache behind ClaudeCodeAdapter:
//  appended-bytes parsing parity with a full re-parse, partial trailing lines
//  across polls, the zero-read unchanged fast path, shrink/rotation recovery,
//  and the per-adapter cache lifetime.
//
//  Created by David Sherlock on 7/16/26.
//

import XCTest
@testable import AgentSession

final class TranscriptCacheTests: XCTestCase {

    // Every test runs against a throwaway projects container (the internal
    // `projectsRoot` seam), never the real ~/.claude/projects.
    private var projectsRoot: URL!

    // The fake project working directory a transcript is keyed to.
    private let root = URL(fileURLWithPath: "/private/tmp/agent-cache-tests/project")

    // The directory ClaudeCodeAdapter derives from `root` inside `projectsRoot`.
    private var projectDir: URL {
        let encoded = String(root.path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        return projectsRoot.appendingPathComponent(encoded, isDirectory: true)
    }

    private var sessionFile: URL { projectDir.appendingPathComponent("session.jsonl") }

    /// A brand-new adapter (cold cache). Used both as the long-lived polled
    /// instance under test and as the full-re-parse oracle: a fresh instance
    /// has never cached anything, so its first answers ARE a full parse.
    private func freshAdapter() -> ClaudeCodeAdapter { ClaudeCodeAdapter(projectsRoot: projectsRoot) }

    override func setUpWithError() throws {
        projectsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-cache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    // MARK: - Transcript plumbing

    // Creates/overwrites the transcript in place (non-atomic: keeps the inode
    // when the file already exists).
    private func write(_ s: String) throws {
        try s.write(to: sessionFile, atomically: false, encoding: .utf8)
    }

    // Appends bytes to the existing transcript — the JSONL steady state the
    // incremental path is built for (same inode, growing size).
    private func append(_ s: String) throws {
        let fh = try FileHandle(forWritingTo: sessionFile)
        fh.seekToEndOfFile()
        fh.write(s.data(using: .utf8)!)
        fh.closeFile()
    }

    // Truncates the transcript in place (same inode, shrinking size).
    private func truncate(to length: UInt64) throws {
        let fh = try FileHandle(forWritingTo: sessionFile)
        fh.truncateFile(atOffset: length)
        fh.closeFile()
    }

    // MARK: - JSONL line factories

    private func userLine(_ text: String) -> String {
        "{\"type\":\"user\",\"timestamp\":\"2026-07-09T10:07:12.000Z\",\"message\":{\"content\":\"\(text)\"}}"
    }

    private func usageLine(id: String, input: Int, output: Int) -> String {
        "{\"type\":\"assistant\",\"message\":{\"id\":\"\(id)\",\"model\":\"claude-sonnet-4\",\"usage\":{\"input_tokens\":\(input),\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":0,\"output_tokens\":\(output)},\"content\":[{\"type\":\"text\",\"text\":\"ok \(id)\"}]}}"
    }

    private func editLine(_ path: String) -> String {
        "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Edit\",\"input\":{\"file_path\":\"\(path)\"}}]}}"
    }

    // MARK: - Parity oracle

    /// Asserts the (cached, previously polled) adapter serves exactly what a
    /// cold adapter's full re-parse of the file's current contents produces,
    /// across all three readers. This is the core semantic guarantee: the cache
    /// changes cost, never results.
    private func assertMatchesFullReparse(_ cached: ClaudeCodeAdapter,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let oracle = freshAdapter()

        let cu = cached.usage(for: root), ou = oracle.usage(for: root)
        XCTAssertEqual(cu == nil, ou == nil, "usage nil-ness diverged", file: file, line: line)
        XCTAssertEqual(cu?.contextTokens, ou?.contextTokens, file: file, line: line)
        XCTAssertEqual(cu?.contextLimit, ou?.contextLimit, file: file, line: line)
        XCTAssertEqual(cu?.outputTokens, ou?.outputTokens, file: file, line: line)
        XCTAssertEqual(cu?.costUSD ?? -1, ou?.costUSD ?? -1, accuracy: 1e-12, file: file, line: line)

        let ce = cached.events(for: root), oe = oracle.events(for: root)
        XCTAssertEqual(ce.count, oe.count, "event counts diverged", file: file, line: line)
        for (l, r) in zip(ce, oe) {
            XCTAssertEqual(l.kind, r.kind, file: file, line: line)
            XCTAssertEqual(l.title, r.title, file: file, line: line)
            XCTAssertEqual(l.detail, r.detail, file: file, line: line)
            XCTAssertEqual(l.filePath, r.filePath, file: file, line: line)
            XCTAssertEqual(l.timestamp, r.timestamp, file: file, line: line)
        }

        let cs = cached.summary(for: root), os = oracle.summary(for: root)
        XCTAssertEqual(cs == nil, os == nil, "summary nil-ness diverged", file: file, line: line)
        XCTAssertEqual(cs?.editedFiles, os?.editedFiles, file: file, line: line)
        XCTAssertEqual(cs?.todos.map { "\($0.text)|\($0.status)" },
                       os?.todos.map { "\($0.text)|\($0.status)" }, file: file, line: line)
    }

    // MARK: - Incremental parity

    // Appended lines parsed incrementally must give identical results to a full
    // re-parse — and each poll must read only the appended bytes, with the one
    // parse shared by all three readers (one content read per changed poll).
    func testAppendedLinesMatchFullReparse() throws {
        let first = userLine("first") + "\n" + usageLine(id: "m1", input: 1000, output: 100) + "\n"
        try write(first)
        let a = freshAdapter()
        assertMatchesFullReparse(a)
        XCTAssertEqual(a.transcriptReadCount, 1)           // one cold read serves all three readers
        XCTAssertEqual(a.transcriptBytesRead, first.utf8.count)

        let second = usageLine(id: "m2", input: 2000, output: 50) + "\n" + editLine("/proj/A.swift") + "\n"
        try append(second)
        assertMatchesFullReparse(a)
        XCTAssertEqual(a.transcriptReadCount, 2)           // one incremental read for the batch
        XCTAssertEqual(a.transcriptBytesRead, first.utf8.count + second.utf8.count) // appended bytes only

        let third = userLine("second") + "\n"
        try append(third)
        assertMatchesFullReparse(a)
        XCTAssertEqual(a.transcriptReadCount, 3)
        XCTAssertEqual(a.transcriptBytesRead, first.utf8.count + second.utf8.count + third.utf8.count)
    }

    // A line whose bytes arrive across two polls: the incomplete prefix must be
    // skipped (exactly as a full re-parse skips a truncated line), the offset
    // must not advance past it, and the completed line must parse on poll two.
    func testPartialTrailingLineCompletedAcrossTwoPolls() throws {
        let full = usageLine(id: "m1", input: 1000, output: 100)
        let cut = full.index(full.startIndex, offsetBy: full.count / 2)
        try write(userLine("hello") + "\n" + String(full[..<cut]))   // ends mid-line, no newline

        let a = freshAdapter()
        XCTAssertNil(a.usage(for: root))                    // half a JSON line is no usage
        XCTAssertEqual(a.events(for: root).count, 1)        // only the complete user line
        assertMatchesFullReparse(a)

        try append(String(full[cut...]) + "\n")             // the rest of the line arrives
        let u = try XCTUnwrap(a.usage(for: root))
        XCTAssertEqual(u.outputTokens, 100)                 // now parsed, exactly once
        XCTAssertEqual(a.events(for: root).count, 2)
        assertMatchesFullReparse(a)
    }

    // A file ending in a complete JSON line WITHOUT a trailing newline (the
    // writer hasn't terminated it yet): a full re-parse sees that line, so the
    // cache must serve it too — tentatively, without folding it into durable
    // state, so it is not double-counted when the newline (and more) arrives.
    func testUnterminatedCompleteLineIsServedOnceNotTwice() throws {
        try write(usageLine(id: "m1", input: 1000, output: 100))     // no trailing "\n"
        let a = freshAdapter()
        XCTAssertEqual(a.usage(for: root)?.outputTokens, 100)        // served now, like a full parse
        assertMatchesFullReparse(a)

        try append("\n" + usageLine(id: "m2", input: 500, output: 25) + "\n")
        XCTAssertEqual(a.usage(for: root)?.outputTokens, 125)        // m1 folded once, not twice
        assertMatchesFullReparse(a)
    }

    // The message-id dedupe set must survive across polls: a duplicate JSONL
    // line for an already-counted response arriving in a LATER poll still
    // counts zero.
    func testDuplicateMessageIDsAcrossPollsStillDedupe() throws {
        try write(usageLine(id: "m1", input: 1000, output: 100) + "\n")
        let a = freshAdapter()
        XCTAssertEqual(a.usage(for: root)?.outputTokens, 100)

        try append(usageLine(id: "m1", input: 1000, output: 100) + "\n")   // duplicate, next poll
        XCTAssertEqual(a.usage(for: root)?.outputTokens, 100)              // still counted once
        assertMatchesFullReparse(a)
    }

    // The 300-event cap applied across several incremental polls must land on
    // exactly the same window as a full parse's suffix(300).
    func testEventCapMatchesFullReparseAcrossPolls() throws {
        try write((0..<250).map { userLine("prompt \($0)") + "\n" }.joined())
        let a = freshAdapter()
        XCTAssertEqual(a.events(for: root).count, 250)

        try append((250..<400).map { userLine("prompt \($0)") + "\n" }.joined())
        let events = a.events(for: root)
        XCTAssertEqual(events.count, 300)
        XCTAssertEqual(events.first?.detail, "prompt 100")
        XCTAssertEqual(events.last?.detail, "prompt 399")
        assertMatchesFullReparse(a)
    }

    // MARK: - The zero-read fast path

    // Polling an unchanged transcript must not read file contents at all — only
    // the initial cold parse touches the bytes.
    func testUnchangedFileDoesZeroReads() throws {
        try write(userLine("hello") + "\n" + usageLine(id: "m1", input: 1000, output: 100) + "\n")
        let a = freshAdapter()
        _ = a.events(for: root)
        XCTAssertEqual(a.transcriptReadCount, 1)
        let bytes = a.transcriptBytesRead

        for _ in 0..<5 {
            _ = a.usage(for: root)
            _ = a.events(for: root)
            _ = a.summary(for: root)
        }
        XCTAssertEqual(a.transcriptReadCount, 1, "unchanged polls must be stat-only")
        XCTAssertEqual(a.transcriptBytesRead, bytes)
        assertMatchesFullReparse(a)
    }

    // MARK: - Invalidation

    // A transcript that SHRANK (same inode) invalidates the cache: one full
    // re-parse, correct results, and incremental appends keep working after.
    func testShrunkFileRecovers() throws {
        let keep = userLine("keep") + "\n"
        try write(keep + usageLine(id: "m1", input: 1000, output: 100) + "\n" + editLine("/proj/A.swift") + "\n")
        let a = freshAdapter()
        XCTAssertEqual(a.events(for: root).count, 3)        // user + assistant text + edit

        try truncate(to: UInt64(keep.utf8.count))
        XCTAssertEqual(a.events(for: root).count, 1)        // re-parsed from scratch
        XCTAssertNil(a.usage(for: root))
        XCTAssertEqual(a.summary(for: root)?.editedFiles, [])
        assertMatchesFullReparse(a)

        try append(editLine("/proj/B.swift") + "\n")        // appends after the shrink still work
        XCTAssertEqual(a.summary(for: root)?.editedFiles, ["/proj/B.swift"])
        assertMatchesFullReparse(a)
    }

    // A newer .jsonl appearing in the project dir (session rotation) must drop
    // the cache for the old file and serve the new session's contents.
    func testSessionRotationSwitchesToNewTranscript() throws {
        try write(userLine("old") + "\n")
        let a = freshAdapter()
        XCTAssertEqual(a.events(for: root).first?.detail, "old")

        let newFile = projectDir.appendingPathComponent("rotated.jsonl")
        try (userLine("new") + "\n").write(to: newFile, atomically: false, encoding: .utf8)
        // Force a strictly newer mtime so latestSessionFile picks it deterministically.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                              ofItemAtPath: newFile.path)

        let events = a.events(for: root)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.detail, "new")
        assertMatchesFullReparse(a)
    }

    // MARK: - Cache lifetime (per adapter value, shared by its copies)

    // The cache is a reference owned by the adapter value: copies share it (no
    // re-read), while an independently constructed adapter starts cold and does
    // its own one full parse. Documented lifetime = the adapter and its copies.
    func testCopiesShareOneCacheAndInstancesAreIndependent() throws {
        try write(userLine("hello") + "\n")
        let a = freshAdapter()
        _ = a.events(for: root)
        XCTAssertEqual(a.transcriptReadCount, 1)

        let copy = a                                        // value copy, same cache reference
        _ = copy.usage(for: root)
        _ = copy.summary(for: root)
        XCTAssertEqual(copy.transcriptReadCount, 1)         // served from the shared cache
        XCTAssertEqual(a.transcriptReadCount, 1)

        let other = freshAdapter()                          // independent instance, cold cache
        _ = other.events(for: root)
        XCTAssertEqual(other.transcriptReadCount, 1)        // its own full parse…
        XCTAssertEqual(a.transcriptReadCount, 1)            // …never touching a's cache
    }

    // MARK: - Thread safety

    // Readers arrive from multiple background queues in the app; hammering the
    // three readers concurrently must be safe and end at the correct answer.
    func testConcurrentPollsAreThreadSafe() throws {
        try write(userLine("hello") + "\n" + usageLine(id: "m1", input: 1000, output: 100) + "\n")
        let a = freshAdapter()
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            switch i % 3 {
            case 0:  _ = a.usage(for: root)
            case 1:  _ = a.events(for: root)
            default: _ = a.summary(for: root)
            }
        }
        XCTAssertEqual(a.transcriptReadCount, 1)            // the parse happened exactly once
        assertMatchesFullReparse(a)
    }
}
