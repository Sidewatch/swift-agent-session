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
public struct ClaudeCodeAdapter: AgentAdapter {

    /// `"Claude Code"`.
    public let name = "Claude Code"

    /// The `~/.claude/projects` container the adapter scans. Internal seam so
    /// tests can point the adapter at a temp directory instead of the real home.
    let projectsRoot: URL

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

    // MARK: - Telemetry

    /// Per-million-token USD prices for one model family.
    private struct Rates { let input, cacheWrite, cacheRead, output: Double }

    /// Approximate list prices by model-name substring (opus / haiku / sonnet default).
    private func rates(for model: String) -> Rates {
        let m = model.lowercased()
        if m.contains("opus")  { return Rates(input: 15, cacheWrite: 18.75, cacheRead: 1.5, output: 75) }
        if m.contains("haiku") { return Rates(input: 0.8, cacheWrite: 1.0, cacheRead: 0.08, output: 4) }
        return Rates(input: 3, cacheWrite: 3.75, cacheRead: 0.3, output: 15)
    }

    /// Token/cost telemetry aggregated over the latest transcript, or `nil` when
    /// there is no transcript or it carries no usage records.
    ///
    /// Cost is estimated from approximate per-model list prices; duplicate JSONL
    /// lines for the same API response (same `message.id`/`requestId`) count once.
    /// - Note: Reads the whole transcript synchronously — call off the main thread
    ///   for large sessions.
    public func usage(for root: URL) -> AgentUsage? {
        guard let file = latestSessionFile(for: root),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var cost = 0.0, totalOut = 0, curCtx = 0, maxCtx = 0
        var model = "claude"
        // Claude Code writes one JSONL line per assistant content block, each repeating
        // the same message id and an identical usage object — count each API response once.
        var seenMessageIDs = Set<String>()
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { continue }
            if let m = msg["model"] as? String, !m.isEmpty, m != "<synthetic>" { model = m }
            let inp = usage["input_tokens"] as? Int ?? 0
            let cw = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cr = usage["cache_read_input_tokens"] as? Int ?? 0
            let out = usage["output_tokens"] as? Int ?? 0
            let id = (msg["id"] as? String) ?? (obj["requestId"] as? String)
            let isDuplicate = id.map { !seenMessageIDs.insert($0).inserted } ?? false
            if !isDuplicate {
                let r = rates(for: model)
                cost += Double(inp) / 1e6 * r.input + Double(cw) / 1e6 * r.cacheWrite
                      + Double(cr) / 1e6 * r.cacheRead + Double(out) / 1e6 * r.output
                totalOut += out
            }
            // Duplicates carry identical values, so the context window is safe to update.
            let ctx = inp + cw + cr + out
            if ctx > 0 { curCtx = ctx }
            maxCtx = max(maxCtx, ctx)
        }
        guard maxCtx > 0 else { return nil }
        let limit = maxCtx > 200_000 ? 1_000_000 : 200_000
        return AgentUsage(contextTokens: curCtx, contextLimit: limit, outputTokens: totalOut, costUSD: cost)
    }

    /// The tools that write to a file on disk. Read-only tools (Read, Grep, Glob, LS)
    /// also carry a path but must NOT be classified as ``TimelineEvent/Kind/fileEdit``.
    private let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]

    // MARK: - Activity timeline

    /// The activity timeline parsed from the latest transcript, oldest first,
    /// capped to the most recent 300 events. Malformed lines are skipped.
    /// - Note: Reads the whole transcript synchronously — call off the main thread
    ///   for large sessions.
    public func events(for root: URL) -> [TimelineEvent] {
        guard let file = latestSessionFile(for: root),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var events: [TimelineEvent] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let msg = obj["message"] as? [String: Any] else { continue }
            let type = obj["type"] as? String ?? ""
            let ts = shortTime(obj["timestamp"] as? String)

            if type == "user" {
                if let s = msg["content"] as? String, !s.hasPrefix("<") {
                    events.append(TimelineEvent(kind: .userPrompt, title: "You", detail: firstLine(s), filePath: nil, timestamp: ts))
                } else if let arr = msg["content"] as? [[String: Any]] {
                    let texts = arr.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }
                    if !texts.isEmpty {
                        events.append(TimelineEvent(kind: .userPrompt, title: "You", detail: firstLine(texts.joined(separator: " ")), filePath: nil, timestamp: ts))
                    }
                }
            } else if type == "assistant", let arr = msg["content"] as? [[String: Any]] {
                for block in arr {
                    switch block["type"] as? String {
                    case "text":
                        if let t = (block["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                            events.append(TimelineEvent(kind: .assistantText, title: "Claude", detail: firstLine(t), filePath: nil, timestamp: ts))
                        }
                    case "tool_use":
                        let name = block["name"] as? String ?? "tool"
                        let input = block["input"] as? [String: Any] ?? [:]
                        let (detail, path) = toolDetail(input)
                        events.append(TimelineEvent(kind: editTools.contains(name) ? .fileEdit : .toolUse, title: name, detail: detail, filePath: path, timestamp: ts))
                    default: break
                    }
                }
            }
        }
        return Array(events.suffix(300))
    }

    // MARK: - Plan vs actual

    /// The edited-files set and the most recent to-do list from the latest
    /// transcript, or `nil` when there is no transcript at all.
    /// - Note: Reads the whole transcript synchronously — call off the main thread
    ///   for large sessions.
    public func summary(for root: URL) -> AgentSummary? {
        guard let file = latestSessionFile(for: root),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var edited = Set<String>()
        var todos: [(String, String)] = []
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let arr = msg["content"] as? [[String: Any]] else { continue }
            for block in arr where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                // NotebookEdit's parameter is notebook_path, not file_path.
                if editTools.contains(name),
                   let fp = (input["file_path"] as? String) ?? (input["notebook_path"] as? String) { edited.insert(fp) }
                // Tolerate a heterogeneous todos array: one malformed element must
                // not drop the valid ones (cast per element, not the whole array).
                if name == "TodoWrite", let ts = input["todos"] as? [Any] {
                    todos = ts.compactMap { item in
                        guard let t = item as? [String: Any],
                              let c = t["content"] as? String else { return nil }
                        return (c, (t["status"] as? String) ?? "pending")
                    }
                }
            }
        }
        return AgentSummary(editedFiles: edited, todos: todos)
    }

    // MARK: - Helpers

    /// Derives a one-line detail string (and a navigable path, when the input
    /// carries one) from a tool call's input dictionary.
    private func toolDetail(_ input: [String: Any]) -> (String, String?) {
        if let fp = input["file_path"] as? String { return (shortPath(fp), fp) }
        if let np = input["notebook_path"] as? String { return (shortPath(np), np) }
        if let p = input["path"] as? String { return (shortPath(p), p) }
        if let cmd = input["command"] as? String { return (firstLine(cmd, 120), nil) }
        if let pat = input["pattern"] as? String { return (pat, nil) }
        if let q = input["query"] as? String { return (firstLine(q, 120), nil) }
        return ("", nil)
    }
    /// The trimmed first line of `s`, truncated to `max` characters with an ellipsis.
    private func firstLine(_ s: String, _ max: Int = 160) -> String {
        let line = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }
    /// Compresses an absolute path to its last two components (`.../Dir/File.swift`).
    private func shortPath(_ p: String) -> String {
        let parts = p.split(separator: "/")
        return parts.count <= 2 ? p : ".../" + parts.suffix(2).joined(separator: "/")
    }
    /// ISO-8601 with fractional seconds ("2026-07-09T10:07:12.000Z") — the form
    /// Claude Code writes. Falls back to `isoPlain` for whole-second timestamps.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    /// Whole-second ISO-8601 fallback ("2026-07-09T10:07:12Z").
    private static let isoPlain = ISO8601DateFormatter()

    /// Renders a `Date` as `HH:mm` on the viewer's local clock.
    private static let localHHMM: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f
    }()

    /// Transcript timestamps are UTC Zulu — convert to the viewer's local clock,
    /// falling back to the raw UTC HH:MM slice only if the string is unparseable.
    private func shortTime(_ iso: String?) -> String {
        guard let iso else { return "" }
        if let date = Self.isoFractional.date(from: iso) ?? Self.isoPlain.date(from: iso) {
            return Self.localHHMM.string(from: date)
        }
        guard let tPart = iso.split(separator: "T").dropFirst().first else { return "" }
        return String(tPart.prefix(5))
    }
}
