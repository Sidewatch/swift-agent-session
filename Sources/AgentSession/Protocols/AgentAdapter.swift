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

    /// Token/cost telemetry for `root`, or `nil` when unavailable.
    func usage(for root: URL) -> AgentUsage?

    /// The edited-files / to-dos roll-up for `root`, or `nil` when unavailable.
    func summary(for root: URL) -> AgentSummary?
}
