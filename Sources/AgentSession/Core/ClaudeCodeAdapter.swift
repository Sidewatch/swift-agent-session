//
//  ClaudeCodeAdapter.swift
//  SwiftAgentSession
//
//  The Claude Code adapter: reads `~/.claude/projects/<encoded-cwd>/<session>.jsonl`
//  (read-only) and maps it onto the agent-agnostic model. The reference adapter.
//
//  Created by David Sherlock on 7/9/26.
//

import Foundation

/// The Claude Code adapter: reads `~/.claude/projects/<cwd-with-nonalphanumerics
/// →dashes>/<session-id>.jsonl` (read-only) and maps it onto the agent-agnostic
/// model. The first, reference ``AgentAdapter``.
///
/// **Performance contract — polling is O(appended bytes).** The three readers
/// (``usage(for:)``, ``events(for:)``, ``summary(for:)``) are served from an
/// internal incremental cache (``TranscriptCache``):
/// - an unchanged transcript is answered from memory (one `stat`, zero reads);
/// - appended lines are read from the last consumed byte offset and parsed
///   *once*, with that single parse shared by all three readers;
/// - a rotated, replaced, or shrunk transcript triggers one full re-parse.
///
/// The results are always identical to a full re-parse of the transcript's
/// current contents — the cache changes cost, never semantics.
///
/// The cache is a reference held by this value, so copies of one adapter share
/// it and it lives exactly as long as the adapter (and its copies). Create one
/// adapter and keep polling it: a freshly constructed adapter starts cold and
/// pays one full parse on first use (``Agents/all`` already holds a single
/// long-lived instance).
public struct ClaudeCodeAdapter: AgentAdapter {

    /// `"Claude Code"`.
    public let name = "Claude Code"

    /// The `~/.claude/projects` container the adapter scans. Internal seam so
    /// tests can point the adapter at a temp directory instead of the real home.
    let projectsRoot: URL

    /// The incremental transcript cache backing the three readers. A reference
    /// type on purpose: copies of this adapter value share the one cache.
    private let cache = TranscriptCache()

    /// Creates an adapter that reads the real `~/.claude/projects` container.
    public init() {
        self.projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Test seam: read transcripts from an arbitrary projects container.
    init(projectsRoot: URL) { self.projectsRoot = projectsRoot }

    /// Whether Claude Code has recorded at least one `.jsonl` transcript for `root`.
    public func hasSession(for root: URL) -> Bool { latestSessionFile(for: root) != nil }

    // MARK: - Locating the transcript

    /// The `~/.claude/projects/<encoded-cwd>` directory for `root`, or `nil` when
    /// Claude Code has never run there.
    func projectDir(for root: URL) -> URL? {
        // Claude Code uses an ASCII-only `[^a-zA-Z0-9]→-` rule; Character.isLetter is
        // Unicode-aware and would keep accented/non-Latin chars, diverging on those paths.
        let encoded = String(root.path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        let dir = projectsRoot.appendingPathComponent(encoded, isDirectory: true)
        var isDir: ObjCBool = false
        return (FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue) ? dir : nil
    }

    /// The most recently modified `.jsonl` transcript in the project directory —
    /// "the current session" — or `nil` when there is none.
    func latestSessionFile(for root: URL) -> URL? {
        guard let dir = projectDir(for: root),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "jsonl" }
            .max { (mod($0) ?? .distantPast) < (mod($1) ?? .distantPast) }
    }

    /// The file's content-modification date, or `nil` when unreadable.
    private func mod(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Readers (served from the incremental cache)

    /// Token/cost telemetry aggregated over the latest transcript, or `nil` when
    /// there is no transcript or it carries no usage records.
    ///
    /// Cost is estimated from approximate per-model list prices; duplicate JSONL
    /// lines for the same API response (same `message.id`/`requestId`) count once.
    /// - Note: Served from the incremental cache — steady-state polls cost
    ///   O(appended bytes) and an unchanged file costs zero reads. The *first*
    ///   call on a large existing session still parses the whole file once, so
    ///   call off the main thread when sessions may be large.
    public func usage(for root: URL) -> AgentUsage? {
        cache.results(for: root, file: latestSessionFile(for: root)).usage
    }

    /// The activity timeline parsed from the latest transcript, oldest first,
    /// capped to the most recent 300 events. Malformed lines are skipped.
    /// - Note: Served from the incremental cache — steady-state polls cost
    ///   O(appended bytes) and an unchanged file costs zero reads. The *first*
    ///   call on a large existing session still parses the whole file once, so
    ///   call off the main thread when sessions may be large.
    public func events(for root: URL) -> [TimelineEvent] {
        cache.results(for: root, file: latestSessionFile(for: root)).events
    }

    /// The edited-files set and the most recent to-do list from the latest
    /// transcript, or `nil` when there is no transcript at all.
    /// - Note: Served from the incremental cache — steady-state polls cost
    ///   O(appended bytes) and an unchanged file costs zero reads. The *first*
    ///   call on a large existing session still parses the whole file once, so
    ///   call off the main thread when sessions may be large.
    public func summary(for root: URL) -> AgentSummary? {
        cache.results(for: root, file: latestSessionFile(for: root)).summary
    }

    // MARK: - Test seams

    /// The number of transcript *content* reads performed so far by this
    /// adapter's cache (`stat`-only polls do not count). Verifies the zero-read
    /// fast path in tests.
    var transcriptReadCount: Int { cache.readCount }

    /// Total transcript bytes read so far by this adapter's cache. With
    /// incremental polling this grows by roughly the appended bytes per poll,
    /// not the file size. Verifies appended-only reads in tests.
    var transcriptBytesRead: Int { cache.bytesRead }
}
