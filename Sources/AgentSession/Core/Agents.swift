//
//  Agents.swift
//  SwiftAgentSession
//
//  The adapter registry and project auto-detection entry point. Add support for
//  an agent by appending its adapter to `all`.
//
//  Created by David Sherlock on 7/9/26.
//

import Foundation

/// Registry of known agent adapters plus project auto-detection.
///
/// Adding support for a new agent is a one-line change: append its
/// ``AgentAdapter`` to ``all``.
public enum Agents {

    /// Every adapter known to the library, in detection order.
    public static let all: [AgentAdapter] = [
        ClaudeCodeAdapter(),
        // CodexAdapter(), GeminiAdapter(), AiderAdapter(), OpenCodeAdapter() — add when verifiable.
    ]

    /// The first adapter that has a session for `root` (first match wins), or
    /// `nil` when no known agent has one.
    public static func active(for root: URL) -> AgentAdapter? {
        all.first { $0.hasSession(for: root) }
    }
}
