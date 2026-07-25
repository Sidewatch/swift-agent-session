//
//  GeminiAdapter.swift
//  SwiftAgentSession
//
//  The Gemini CLI adapter: reads `~/.gemini/tmp/<projectID>/chats/*.json|.jsonl`.
//
//  Created by David Sherlock on 7/26/26.
//

import Foundation

/// Reads Gemini CLI chat sessions.
///
/// The layout and schema come from gemini-cli's own source (Apache-2.0,
/// `packages/core/src/config/storage.ts`, `config/projectRegistry.ts` and
/// `services/chatRecordingTypes.ts`):
///
/// ```
/// ~/.gemini/tmp/<projectID>/.project_root   the project path this directory belongs to
/// ~/.gemini/tmp/<projectID>/chats/*.json    a whole ConversationRecord
/// ~/.gemini/tmp/<projectID>/chats/*.jsonl   a metadata line, then one MessageRecord per line
/// ```
///
/// ### The third locating strategy
/// Claude keys transcripts by an encoded project path; Codex hides the path inside the file;
/// Gemini uses an opaque `<projectID>` that is a **registry-assigned slug** — not derivable from
/// the path — and older installs use a sha256 hash of it instead. Rather than reproduce either
/// scheme (and get the migration boundary wrong), this reads the `.project_root` marker Gemini
/// writes into each directory, which names the owning project directly and is correct for slug
/// and legacy-hash directories alike.
///
/// - Important: Written against the published schema, **not** against a session produced by a
///   real Gemini CLI run.
public final class GeminiAdapter: AgentAdapter {

    public let name = "Gemini CLI"

    /// The `~/.gemini/tmp` container this adapter scans.
    let tempRoot: URL

    /// Creates an adapter reading the real `~/.gemini/tmp`.
    public init() {
        self.tempRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/tmp", isDirectory: true)
    }

    /// Test seam: read from an arbitrary temp container.
    init(tempRoot: URL) { self.tempRoot = tempRoot }

    public func hasSession(for root: URL) -> Bool { latestChatFile(for: root) != nil }

    public func events(for root: URL) -> [TimelineEvent] {
        guard let file = latestChatFile(for: root) else { return [] }
        return events(fromSession: file)
    }

    /// Gemini records token summaries per message; not read yet, so the Usage dashboard stays
    /// Claude-only rather than showing a confidently wrong zero.
    public func usage(for root: URL) -> AgentUsage? { nil }

    public func summary(for root: URL) -> AgentSummary? {
        let events = events(for: root)
        guard !events.isEmpty else { return nil }
        return AgentSummary(editedFiles: Set(events.compactMap { $0.kind == .fileEdit ? $0.filePath : nil }),
                            todos: [])
    }

    /// The timeline for one chat file, in either of the two shapes Gemini writes.
    public func events(fromSession url: URL) -> [TimelineEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Self.messages(in: data).flatMap(Self.events(for:))
    }

    // MARK: - Reading either file shape

    /// The message records in a chat file.
    ///
    /// A `.json` file is one whole `ConversationRecord` with a `messages` array; a `.jsonl` file
    /// is a metadata line followed by one record per line. Both are accepted by shape rather than
    /// by extension, because the same directory holds both and an install can be mid-migration.
    static func messages(in data: Data) -> [[String: Any]] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messages = object["messages"] as? [[String: Any]] {
            return messages
        }
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return nil }
            // The leading metadata record carries sessionId but no type — skip it.
            return object["type"] == nil ? nil : object
        }
    }

    /// The timeline rows for one message record.
    static func events(for message: [String: Any]) -> [TimelineEvent] {
        let time = TranscriptState.shortTime(message["timestamp"] as? String)
        let text = partsText(message["content"])

        switch message["type"] as? String {
        case "user":
            guard !text.isEmpty else { return [] }
            return [TimelineEvent(kind: .userPrompt, title: "You", detail: TranscriptState.firstLine(text),
                                  filePath: nil, timestamp: time)]

        case "gemini":
            var events: [TimelineEvent] = []
            if !text.isEmpty {
                events.append(TimelineEvent(kind: .assistantText, title: "Gemini",
                                            detail: TranscriptState.firstLine(text),
                                            filePath: nil, timestamp: time))
            }
            // Tool calls hang off the assistant record rather than being records of their own.
            for call in message["toolCalls"] as? [[String: Any]] ?? [] {
                let name = call["name"] as? String ?? "tool"
                let args = call["args"] as? [String: Any] ?? [:]
                let path = editedPath(tool: name, args: args)
                let callTime = TranscriptState.shortTime(call["timestamp"] as? String)
                events.append(TimelineEvent(kind: path != nil ? .fileEdit : .toolUse, title: name,
                                            detail: path ?? TranscriptState.firstLine(describe(args)),
                                            filePath: path,
                                            timestamp: callTime.isEmpty ? time : callTime))
            }
            return events

        default:
            // info / error / warning are UI notices, not conversation.
            return []
        }
    }

    /// Flattens Gemini's `PartListUnion` into text.
    ///
    /// It is a string, a single `{text}` part, or an array of them — all three appear in stored
    /// records, so a parser that assumes one silently loses messages.
    static func partsText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        if let part = content as? [String: Any] { return part["text"] as? String ?? "" }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: " ")
        }
        return ""
    }

    /// The file a Gemini tool call wrote to, or `nil` when it isn't an edit.
    static func editedPath(tool: String, args: [String: Any]) -> String? {
        // Gemini's write tools: `replace` (its edit tool), `write_file`, `edit`.
        let writers: Set<String> = ["replace", "write_file", "edit", "writefile"]
        guard writers.contains(tool.lowercased()) else { return nil }
        for key in ["file_path", "filePath", "path", "absolute_path"] {
            if let value = args[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// A one-line rendering of a tool's arguments, for the row detail.
    private static func describe(_ args: [String: Any]) -> String {
        for key in ["command", "pattern", "query", "prompt", "file_path", "path"] {
            if let value = args[key] as? String, !value.isEmpty { return value }
        }
        return args.keys.sorted().joined(separator: ", ")
    }

    // MARK: - Locating a session

    /// The `~/.gemini/tmp/<projectID>` directory owning `root`, found via its `.project_root`
    /// marker.
    func projectDir(for root: URL) -> URL? {
        let target = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: tempRoot, includingPropertiesForKeys: nil) else { return nil }
        for dir in dirs {
            let marker = dir.appendingPathComponent(".project_root")
            guard let owner = try? String(contentsOf: marker, encoding: .utf8) else { continue }
            let path = owner.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty,
               URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path == target {
                return dir
            }
        }
        return nil
    }

    /// The most recently modified chat file for `root`.
    func latestChatFile(for root: URL) -> URL? {
        guard let dir = projectDir(for: root)?.appendingPathComponent("chats", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "json" || $0.pathExtension == "jsonl" }
            .max { (Self.modified($0) ?? .distantPast) < (Self.modified($1) ?? .distantPast) }
    }

    private static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
