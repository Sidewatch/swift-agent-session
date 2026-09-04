//
//  OpenCodeAdapter.swift
//  SwiftAgentSession
//
//  The OpenCode adapter: reads a session stored as a DIRECTORY of per-message and per-part JSON.
//
//  Created by David Sherlock on 7/26/26.
//

import Foundation

/// Reads OpenCode sessions.
///
/// The layout comes from OpenCode's own source (MIT, `packages/opencode/src/storage/storage.ts`
/// and `packages/core/src/global.ts`):
///
/// ```
/// $XDG_DATA_HOME/opencode/storage/       (macOS default: ~/.local/share/opencode/storage)
///   project/<projectID>.json             which working directory a project is
///   session/<projectID>/<sessionID>.json session info
///   message/<sessionID>/<messageID>.json role + metadata, NO content
///   part/<messageID>/<partID>.json       the content: text, tool calls, reasoning
/// ```
///
/// ### Why this adapter doesn't use `TranscriptCache`
/// Claude and Codex append to a single JSONL file, so polling is O(appended bytes) via a stat and
/// an offset. OpenCode writes **one small JSON file per message and per part**, so there is no
/// tail to read — a refresh means re-listing directories. The incremental cache would buy nothing
/// and its file-identity checks (inode, size, offset) are meaningless here, so this reads
/// directly and keeps the cost honest instead of pretending.
///
/// - Important: Written against the published storage layout and schema, **not** against a
///   session produced by a real OpenCode run. The shapes are right; which fields are populated in
///   practice is unconfirmed.
public final class OpenCodeAdapter: AgentAdapter {

    public let name = "OpenCode"

    /// The `storage` container this adapter reads.
    let storageRoot: URL

    /// Creates an adapter reading the real OpenCode storage.
    ///
    /// `$XDG_DATA_HOME` when set, else `~/.local/share` — the `xdg-basedir` behaviour OpenCode
    /// relies on, which resolves the same way on macOS as on Linux.
    public init() {
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share", isDirectory: true)
        self.storageRoot = data
            .appendingPathComponent("opencode/storage", isDirectory: true)
    }

    /// Test seam: read from an arbitrary storage container.
    init(storageRoot: URL) { self.storageRoot = storageRoot }

    /// Memoizes located sessions and parsed events — see ``SessionMemo``.
    private let locationMemo = SessionMemo<URL?>()
    private let eventsMemo = SessionMemo<[TimelineEvent]>()

    public func hasSession(for root: URL) -> Bool { memoizedSessionDir(for: root) != nil }

    public func events(for root: URL) -> [TimelineEvent] {
        eventsMemo.value(for: root.path) {
            guard let dir = memoizedSessionDir(for: root) else { return [] }
            return events(fromSession: dir)
        }
    }

    /// ``latestSessionDir(for:)`` behind the memo — it walks directories and reads JSON, and the
    /// 2s poll asks for it repeatedly.
    private func memoizedSessionDir(for root: URL) -> URL? {
        locationMemo.value(for: root.path) { latestSessionDir(for: root) }
    }

    /// Token/cost telemetry summed over the session's assistant messages.
    ///
    /// OpenCode records `cost` directly, so this is real spend rather than an estimate from a
    /// price list. `contextLimit` is left at zero — OpenCode does not record the model's window,
    /// and `AgentUsage.contextPercent` reports 0 for an unknown limit rather than inventing one.
    public func usage(for root: URL) -> AgentUsage? {
        guard let dir = memoizedSessionDir(for: root),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }

        var context = 0, output = 0, cost = 0.0, sawAny = false
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            guard let message = JSONFile.object(at: file), let tokens = Self.tokens(in: message) else { continue }
            sawAny = true
            let input = (tokens["input"] as? Double ?? 0)
                + ((tokens["cache"] as? [String: Any])?["read"] as? Double ?? 0)
                + ((tokens["cache"] as? [String: Any])?["write"] as? Double ?? 0)
            let out = tokens["output"] as? Double ?? 0
            // Context is the LATEST message's footprint, not the sum: it is a window fill.
            context = Int(input + out + (tokens["reasoning"] as? Double ?? 0))
            output += Int(out)
            cost += Self.cost(in: message)
        }
        guard sawAny else { return nil }
        return AgentUsage(contextTokens: context, contextLimit: 0, outputTokens: output, costUSD: cost)
    }

    /// The `tokens` object on an assistant message, wherever the schema nests it.
    ///
    /// It has lived at the top level and under `metadata.assistant` across versions, so this
    /// probes rather than hard-coding one path that a release renames.
    static func tokens(in message: [String: Any]) -> [String: Any]? {
        if let tokens = message["tokens"] as? [String: Any] { return tokens }
        if let metadata = message["metadata"] as? [String: Any] {
            if let tokens = metadata["tokens"] as? [String: Any] { return tokens }
            if let assistant = metadata["assistant"] as? [String: Any],
               let tokens = assistant["tokens"] as? [String: Any] { return tokens }
        }
        return nil
    }

    /// The `cost` on an assistant message, probed the same way.
    static func cost(in message: [String: Any]) -> Double {
        if let cost = message["cost"] as? Double { return cost }
        if let metadata = message["metadata"] as? [String: Any] {
            if let cost = metadata["cost"] as? Double { return cost }
            if let assistant = metadata["assistant"] as? [String: Any],
               let cost = assistant["cost"] as? Double { return cost }
        }
        return 0
    }

    public func summary(for root: URL) -> AgentSummary? {
        // events(for:) is memoized, so this no longer re-reads the whole session.
        let events = events(for: root)
        guard !events.isEmpty else { return nil }
        let edited = Set(events.compactMap { $0.kind == .fileEdit ? $0.filePath : nil })
        return AgentSummary(editedFiles: edited, todos: [])
    }

    /// The timeline for one session, given its **message directory**
    /// (`storage/message/<sessionID>`).
    ///
    /// Parts live in a sibling tree (`storage/part/<messageID>`), so the parts directory is
    /// resolved relative to the one passed in. That keeps the seam a single URL while matching a
    /// layout that splits one conversation across two directory trees.
    public func events(fromSession url: URL) -> [TimelineEvent] {
        let partsRoot = url.deletingLastPathComponent()     // storage/message
            .deletingLastPathComponent()                    // storage
            .appendingPathComponent("part", isDirectory: true)
        guard let messageFiles = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil) else { return [] }

        var events: [TimelineEvent] = []
        // Message ids are monotonic, so sorting by filename restores conversation order without
        // reading every file first.
        for messageFile in messageFiles.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            guard let message = JSONFile.object(at: messageFile) else { continue }
            let role = message["role"] as? String ?? ""
            let time = Self.time(message)
            let messageID = message["id"] as? String ?? messageFile.deletingPathExtension().lastPathComponent
            events += Self.events(forMessageID: messageID, role: role, time: time, partsRoot: partsRoot)
        }
        return events
    }

    // MARK: - Parts

    /// The timeline rows contributed by one message's parts.
    private static func events(forMessageID id: String, role: String, time: String,
                               partsRoot: URL) -> [TimelineEvent] {
        let dir = partsRoot.appendingPathComponent(id, isDirectory: true)
        guard let partFiles = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }

        var events: [TimelineEvent] = []
        for partFile in partFiles.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            guard let part = JSONFile.object(at: partFile) else { continue }
            switch part["type"] as? String {
            case "text":
                guard let text = part["text"] as? String,
                      !text.trimmed.isEmpty else { continue }
                events.append(TimelineEvent(kind: role == "user" ? .userPrompt : .assistantText,
                                            title: role == "user" ? "You" : "OpenCode",
                                            detail: TranscriptState.firstLine(text),
                                            filePath: nil, timestamp: time))
            case "tool":
                let tool = part["tool"] as? String ?? "tool"
                // The call's arguments live under state.input once the tool has run.
                let state = part["state"] as? [String: Any] ?? [:]
                let input = state["input"] as? [String: Any] ?? part["input"] as? [String: Any] ?? [:]
                let path = editedPath(tool: tool, input: input)
                events.append(TimelineEvent(kind: path != nil ? .fileEdit : .toolUse,
                                            title: tool,
                                            detail: path ?? TranscriptState.firstLine(describe(input)),
                                            filePath: path, timestamp: time))
            default:
                // reasoning, step-start, snapshot… — no timeline row.
                continue
            }
        }
        return events
    }

    /// The file an OpenCode tool call wrote to, or `nil` when it isn't an edit.
    ///
    /// Only *writing* tools count: reporting a read as an edit would put files in the review
    /// surface that the agent never changed.
    static func editedPath(tool: String, input: [String: Any]) -> String? {
        let writers: Set<String> = ["edit", "write", "patch", "multiedit", "apply_patch"]
        guard writers.contains(tool.lowercased()) else { return nil }
        for key in ["filePath", "file_path", "path", "filename"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// A one-line rendering of a tool's arguments, for the row detail.
    private static func describe(_ input: [String: Any]) -> String {
        for key in ["command", "pattern", "query", "description", "filePath", "path"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return input.keys.sorted().joined(separator: ", ")
    }

    // MARK: - Locating a session

    /// The project ids whose recorded working directory is `root`.
    ///
    /// OpenCode keys sessions by an opaque project id, and the mapping from id back to a
    /// directory lives in `project/<id>.json`. The field naming has moved around across
    /// versions, so any string value that resolves to `root` counts as a match rather than
    /// hard-coding one key that a later release renames.
    func projectIDs(for root: URL) -> [String] {
        let target = root.standardizedFileURL.resolvingSymlinksInPath().path
        let dir = storageRoot.appendingPathComponent("project", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let object = JSONFile.object(at: file) else { return nil }
            let matches = object.values.contains { value in
                guard let path = value as? String, path.hasPrefix("/") else { return false }
                return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == target
            }
            return matches ? file.deletingPathExtension().lastPathComponent : nil
        }
    }

    /// The message directory of the most recently updated session recorded for `root`.
    func latestSessionDir(for root: URL) -> URL? {
        let sessionIDs = projectIDs(for: root).flatMap { projectID -> [URL] in
            let dir = storageRoot.appendingPathComponent("session/\(projectID)", isDirectory: true)
            return (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        }
        let newest = sessionIDs.filter { $0.pathExtension == "json" }
            .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
        guard let sessionID = newest?.deletingPathExtension().lastPathComponent else { return nil }
        let messages = storageRoot.appendingPathComponent("message/\(sessionID)", isDirectory: true)
        return messages.isExistingDirectory ? messages : nil
    }

    /// `HH:MM` for a message, from whichever time field it carries: epoch milliseconds, nested
    /// under `time.created` on newer records.
    private static func time(_ message: [String: Any]) -> String {
        let millis = (message["time"] as? [String: Any])?["created"] as? Double
            ?? message["created"] as? Double
        guard let millis else { return "" }
        return ClockFormat.hhmm(Date(epochMilliseconds: millis))
    }
}
