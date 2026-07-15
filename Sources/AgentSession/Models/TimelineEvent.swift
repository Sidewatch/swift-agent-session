//
//  TimelineEvent.swift
//  SwiftAgentSession
//
//  A single entry in an agent's activity timeline — a user prompt, a line of
//  assistant text, a tool call, or a file edit — in the agent-agnostic model.
//
//  Created by David Sherlock on 7/9/26.
//

import Foundation

/// One entry in an agent's activity timeline, normalized across agents.
///
/// Adapters map each agent's own transcript format onto a stream of these, so a
/// review surface can render any agent's activity identically.
public struct TimelineEvent {

    /// The category of a timeline entry, which drives its glyph and styling.
    public enum Kind {

        /// A prompt typed by the human operator.
        case userPrompt

        /// A line of assistant (model) prose.
        case assistantText

        /// A tool invocation that is not a file edit (shell, search, …).
        case toolUse

        /// A tool invocation that writes to a file on disk.
        case fileEdit
    }

    /// The category of this entry.
    public let kind: Kind

    /// A short title — the speaker (`"You"` / `"Claude"`) or the tool name.
    public let title: String

    /// The one-line detail: prompt text, prose, a command, or a shortened path.
    public let detail: String

    /// The file this entry touched, if any (for `.fileEdit` and path tools).
    public let filePath: String?

    /// A short `HH:MM` timestamp, or `""` when unknown.
    public let timestamp: String

    /// Creates a timeline entry.
    public init(kind: Kind, title: String, detail: String, filePath: String?, timestamp: String) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.filePath = filePath
        self.timestamp = timestamp
    }
}
