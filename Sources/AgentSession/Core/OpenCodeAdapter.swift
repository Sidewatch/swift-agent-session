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

    /// OpenCode records token usage per message; not read yet, so the Usage dashboard stays
    /// Claude-only rather than showing a confidently wrong zero.
    public func usage(for root: URL) -> AgentUsage? { nil }

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
            guard let message = Self.json(at: messageFile) else { continue }
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
            guard let part = json(at: partFile) else { continue }
            switch part["type"] as? String {
            case "text":
                guard let text = part["text"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
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
            guard let object = Self.json(at: file) else { return nil }
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
            .max { (Self.modified($0) ?? .distantPast) < (Self.modified($1) ?? .distantPast) }
        guard let sessionID = newest?.deletingPathExtension().lastPathComponent else { return nil }
        let messages = storageRoot.appendingPathComponent("message/\(sessionID)", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: messages.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return messages
    }

    // MARK: - Helpers

    private static func json(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// `HH:mm` in a fixed locale.
    ///
    /// A `DateFormatter` with an explicit `dateFormat` still honours the user's locale, so under
    /// a 12-hour region the pattern is rewritten and OpenCode rows would render differently from
    /// every other adapter's. `en_US_POSIX` pins it. Built once — DateFormatter is expensive.
    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// `HH:MM` for a message, from whichever time field it carries.
    ///
    /// OpenCode records epoch **milliseconds** (nested under `time.created` on newer records),
    /// not an ISO string — treating it as seconds would date every row to 1970.
    private static func time(_ message: [String: Any]) -> String {
        let millis = (message["time"] as? [String: Any])?["created"] as? Double
            ?? message["created"] as? Double
        guard let millis else { return "" }
        return Self.hhmm.string(from: Date(timeIntervalSince1970: millis / 1000))
    }
}
