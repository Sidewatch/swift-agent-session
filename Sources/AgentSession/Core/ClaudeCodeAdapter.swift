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
    public let name = "Claude Code"

    public init() {}

    public func hasSession(for root: URL) -> Bool { latestSessionFile(for: root) != nil }

    // MARK: - Locating the transcript

    func projectDir(for root: URL) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Claude Code uses an ASCII-only `[^a-zA-Z0-9]→-` rule; Character.isLetter is
        // Unicode-aware and would keep accented/non-Latin chars, diverging on those paths.
        let encoded = String(root.path.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
        let dir = home.appendingPathComponent(".claude/projects/\(encoded)", isDirectory: true)
        var isDir: ObjCBool = false
        return (FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue) ? dir : nil
    }

    func latestSessionFile(for root: URL) -> URL? {
        guard let dir = projectDir(for: root),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "jsonl" }
            .max { (mod($0) ?? .distantPast) < (mod($1) ?? .distantPast) }
    }

    private func mod(_ u: URL) -> Date? {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // MARK: - Telemetry

    private struct Rates { let input, cacheWrite, cacheRead, output: Double }
    private func rates(for model: String) -> Rates {
        let m = model.lowercased()
        if m.contains("opus")  { return Rates(input: 15, cacheWrite: 18.75, cacheRead: 1.5, output: 75) }
        if m.contains("haiku") { return Rates(input: 0.8, cacheWrite: 1.0, cacheRead: 0.08, output: 4) }
        return Rates(input: 3, cacheWrite: 3.75, cacheRead: 0.3, output: 15)
    }

    public func usage(for root: URL) -> AgentUsage? {
        guard let file = latestSessionFile(for: root),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var cost = 0.0, totalOut = 0, curCtx = 0, maxCtx = 0
        var model = "claude"
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
            let r = rates(for: model)
            cost += Double(inp) / 1e6 * r.input + Double(cw) / 1e6 * r.cacheWrite
                  + Double(cr) / 1e6 * r.cacheRead + Double(out) / 1e6 * r.output
            totalOut += out
            let ctx = inp + cw + cr + out
            if ctx > 0 { curCtx = ctx }
            maxCtx = max(maxCtx, ctx)
        }
        guard maxCtx > 0 else { return nil }
        let limit = maxCtx > 200_000 ? 1_000_000 : 200_000
        return AgentUsage(contextTokens: curCtx, contextLimit: limit, outputTokens: totalOut, costUSD: cost)
    }

    // MARK: - Activity timeline

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
                        events.append(TimelineEvent(kind: path != nil ? .fileEdit : .toolUse, title: name, detail: detail, filePath: path, timestamp: ts))
                    default: break
                    }
                }
            }
        }
        return Array(events.suffix(300))
    }

    // MARK: - Plan vs actual

    public func summary(for root: URL) -> AgentSummary? {
        guard let file = latestSessionFile(for: root),
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        var edited = Set<String>()
        var todos: [(String, String)] = []
        let editTools: Set<String> = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let msg = obj["message"] as? [String: Any],
                  let arr = msg["content"] as? [[String: Any]] else { continue }
            for block in arr where block["type"] as? String == "tool_use" {
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                if editTools.contains(name), let fp = input["file_path"] as? String { edited.insert(fp) }
                if name == "TodoWrite", let ts = input["todos"] as? [[String: Any]] {
                    todos = ts.compactMap { t in
                        guard let c = t["content"] as? String else { return nil }
                        return (c, (t["status"] as? String) ?? "pending")
                    }
                }
            }
        }
        return AgentSummary(editedFiles: edited, todos: todos)
    }

    // MARK: - Helpers

    private func toolDetail(_ input: [String: Any]) -> (String, String?) {
        if let fp = input["file_path"] as? String { return (shortPath(fp), fp) }
        if let p = input["path"] as? String { return (shortPath(p), p) }
        if let cmd = input["command"] as? String { return (firstLine(cmd, 120), nil) }
        if let pat = input["pattern"] as? String { return (pat, nil) }
        if let q = input["query"] as? String { return (firstLine(q, 120), nil) }
        return ("", nil)
    }
    private func firstLine(_ s: String, _ max: Int = 160) -> String {
        let line = s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.count > max ? String(t.prefix(max)) + "…" : t
    }
    private func shortPath(_ p: String) -> String {
        let parts = p.split(separator: "/")
        return parts.count <= 2 ? p : ".../" + parts.suffix(2).joined(separator: "/")
    }
    private func shortTime(_ iso: String?) -> String {
        guard let iso, let tPart = iso.split(separator: "T").dropFirst().first else { return "" }
        return String(tPart.prefix(5))
    }
}
