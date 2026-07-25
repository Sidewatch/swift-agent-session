//
//  AgentAdapter.swift
//  SwiftAgentSession
//
//  The read-only bridge between a CLI coding agent's on-disk session transcript
//  and the agent-agnostic model. Implement one per agent.
//
//  Created by David Sherlock on 7/9/26.
//

import Foundation

/// A CLI coding agent whose on-disk session transcript can be read (read-only).
///
/// Implement one adapter per agent to map its native session format onto the
/// shared ``TimelineEvent`` / ``AgentUsage`` / ``AgentSummary`` model; every
/// other consumer then stays agent-agnostic.
///
/// - Note: Adapters read transcripts synchronously from disk — call off the main
///   thread when sessions may be large.
public protocol AgentAdapter {

    /// A human-readable name for the agent, e.g. `"Claude Code"`.
    var name: String { get }

    /// Whether this agent has a recorded session for the given project root.
    func hasSession(for root: URL) -> Bool

    /// The activity timeline for `root`, oldest first.
    func events(for root: URL) -> [TimelineEvent]

    /// The activity timeline parsed from one session on disk, wherever it happens to live.
    ///
    /// An adapter does two separable jobs: *locating* an agent's transcript (which directory,
    /// which session file, which is newest) and *parsing* it. This is the parsing half on its
    /// own, and it's what makes an adapter developable against a checked-in fixture — so a new
    /// agent's adapter can be written, tested and maintained **without installing that agent**.
    /// `Sidewatch --dump-session <file>` is this method, headless.
    ///
    /// - Parameter url: A session in this agent's own format. Usually a transcript **file**
    ///   (Claude, Codex), but some agents don't keep one: OpenCode stores a session as a
    ///   **directory** of per-message JSON, so this deliberately takes a URL of either kind and
    ///   lets the adapter decide what it means.
    /// - Returns: The timeline, oldest first. Empty when the session is absent or unparseable —
    ///   a session in the wrong format is not an error, just not this agent's.
    func events(fromSession url: URL) -> [TimelineEvent]

    /// Token/cost telemetry for `root`, or `nil` when unavailable.
    func usage(for root: URL) -> AgentUsage?

    /// The edited-files / to-dos roll-up for `root`, or `nil` when unavailable.
    func summary(for root: URL) -> AgentSummary?
}
