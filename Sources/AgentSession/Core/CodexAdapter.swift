//
//  CodexAdapter.swift
//  SwiftAgentSession
//
//  The Codex CLI adapter: reads `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-*.jsonl` (read-only)
//  and maps it onto the agent-agnostic model.
//
//  Created by David Sherlock on 7/26/26.
//

import Foundation

/// Reads OpenAI Codex CLI session rollouts.
///
/// The format is taken from Codex's own source (Apache-2.0, `codex-rs/rollout/src/recorder.rs`
/// and `codex-rs/protocol/src/protocol.rs`), not from guesswork: each line is a `RolloutLine`
/// serialised as `{"timestamp":…, "ordinal":…, "type":<tag>, "payload":{…}}` —
/// `#[serde(tag = "type", content = "payload")]` — where the payload of a `response_item` is
/// itself an internally-tagged `ResponseItem`.
///
/// - Important: This adapter was written against the published schema and a synthetic fixture,
///   **not** against a transcript produced by a real Codex run. The shapes are right; which
///   fields Codex actually populates in practice is unconfirmed. Treat surprises as this
///   adapter's fault, not the user's.
///
/// ### Why locating a session is different from Claude
/// Claude Code keys transcripts by the project directory, so finding one is a path lookup. Codex
/// files are keyed by **date and UUID**, and the working directory only appears *inside* the
/// file (in a `turn_context` record). Finding "the session for this project" therefore means
/// scanning newest-first and reading each file's head until one matches — bounded by
/// ``scanLimit`` so a long Codex history can't turn a poll into a directory crawl.
public final class CodexAdapter: AgentAdapter {

    public let name = "Codex"

    /// The `sessions` container this adapter scans.
    let sessionsRoot: URL

    /// How many rollout files to inspect before giving up on matching a project.
    ///
    /// Sessions are visited newest-first, so the match for an active project is normally the
    /// first file. The cap exists so a machine with years of Codex history doesn't pay for a
    /// full crawl on every poll.
    static let scanLimit = 60

    private let cache = TranscriptCache(format: .codex)
    /// Locating a Codex session walks the sessions tree and head-reads up to
    /// ``scanLimit`` rollouts; the 2s poll asks three times per tick (has/events/summary).
    private let locationMemo = SessionMemo<URL?>()

    /// Creates an adapter reading the real `$CODEX_HOME/sessions` (defaulting to `~/.codex`).
    public init() {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        self.sessionsRoot = home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Test seam: read rollouts from an arbitrary sessions container.
    init(sessionsRoot: URL) { self.sessionsRoot = sessionsRoot }

    public func hasSession(for root: URL) -> Bool { memoizedSessionFile(for: root) != nil }

    public func events(for root: URL) -> [TimelineEvent] {
        cache.results(for: root, file: memoizedSessionFile(for: root)).events
    }

    /// Codex records token usage in its own event stream; this adapter does not read it yet, so
    /// the Usage dashboard stays Claude-only rather than showing a confidently wrong zero.
    public func usage(for root: URL) -> AgentUsage? { nil }

    public func summary(for root: URL) -> AgentSummary? {
        cache.results(for: root, file: memoizedSessionFile(for: root)).summary
    }

    public func events(fromSession url: URL) -> [TimelineEvent] {
        cache.results(for: url, file: url).events
    }

    /// ``latestSessionFile(for:)`` behind the memo.
    private func memoizedSessionFile(for root: URL) -> URL? {
        locationMemo.value(for: root.path) { latestSessionFile(for: root) }
    }

    // MARK: - Locating a session

    /// Every rollout file, newest first (the tree is `sessions/YYYY/MM/DD/`, so a lexical sort
    /// of the relative path is already chronological).
    func rolloutFiles() -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        let files = walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        return files.sorted { $0.path > $1.path }
    }

    /// The newest rollout whose recorded working directory is `root`.
    func latestSessionFile(for root: URL) -> URL? {
        let target = root.standardizedFileURL.resolvingSymlinksInPath().path
        for file in rolloutFiles().prefix(Self.scanLimit) {
            if let cwd = Self.recordedCWD(in: file),
               URL(fileURLWithPath: cwd).standardizedFileURL.resolvingSymlinksInPath().path == target {
                return file
            }
        }
        return nil
    }

    /// The working directory a rollout records, read from its first `turn_context`.
    ///
    /// Only the head of the file is read: `cwd` appears near the top, and a rollout can grow to
    /// megabytes, so matching a project must not cost a full parse per candidate file.
    static func recordedCWD(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        // `readData(ofLength:)` rather than `read(upToCount:)`: the package deploys to
        // macOS 10.15, and the throwing variant is 10.15.4+.
        let head = handle.readData(ofLength: 64 * 1024)
        // A fixed byte cut can land inside a multi-byte sequence, and strict UTF-8 decoding then
        // returns nil for the WHOLE head — losing cwd even though it sits on line 1. Drop the
        // trailing partial character rather than the file.
        guard let text = Self.lenientUTF8(head) else { return nil }
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            // `turn_context` carries it directly; `session_meta` nests it under `meta`.
            if let cwd = payload["cwd"] as? String { return cwd }
            if let meta = payload["meta"] as? [String: Any], let cwd = meta["cwd"] as? String { return cwd }
        }
        return nil
    }

    /// Decodes `data` as UTF-8, discarding a truncated final character rather than failing.
    ///
    /// The head read is a fixed byte count, so it can land inside a multi-byte sequence. Strict
    /// decoding then returns nil for the WHOLE buffer, which would lose `cwd` even when it sits
    /// on line 1 — and the session would be permanently invisible to the app.
    static func lenientUTF8(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        // A UTF-8 sequence is at most 4 bytes, so at most 3 trailing bytes can be partial.
        for drop in 1...3 where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return nil
    }
}
