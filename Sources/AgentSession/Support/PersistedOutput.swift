//
//  PersistedOutput.swift
//  AgentSession
//
//  A tool result Claude Code spilled to a file, read back from that file's tail.
//
//  Created by David Sherlock on 9/24/26.
//

import Foundation

/// Claude Code keeps a large tool output OUT of the transcript: the `tool_result` block holds a
/// `<persisted-output>` stub — "Output too large (37.3KB). Full output saved to: <path>" and a
/// 2 KB preview of the START — and the whole output sits in the session's `tool-results/`
/// folder (24 Sep 2026, seen in every recent transcript on David's machine). A reader that
/// wants the END of a result — a test runner's summary line, a migration's last message — must
/// follow the path. Only a file in a `tool-results` folder is followed; anything else stays as
/// the transcript wrote it.
public enum PersistedOutput {
    public static let marker = "<persisted-output>"

    /// The path a stub names, or nil for text that is not a stub.
    public static func savedPath(in text: String) -> String? {
        guard text.hasPrefix(marker), let range = text.range(of: "Full output saved to: ") else { return nil }
        let rest = text[range.upperBound...]
        let line = rest.prefix { !$0.isNewline }
        let path = line.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent == "tool-results" else { return nil }
        return path
    }

    /// `text` with a stub replaced by the last `cap` characters of the file it names (an ellipsis
    /// first when cut), or `text` itself when it is no stub or the file cannot be read.
    public static func resolved(_ text: String, cap: Int, read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> String {
        guard let path = savedPath(in: text), let full = read(path) else { return text }
        return full.count > cap ? "…" + String(full.suffix(cap)) : full
    }
}
