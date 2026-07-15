//
//  AgentUsage.swift
//  SwiftAgentSession
//
//  Token and cost telemetry for the current agent session, derived from the
//  transcript's usage records.
//
//  Created by David Sherlock on 7/9/26.
//

import Foundation

/// Token/cost telemetry for an agent session.
public struct AgentUsage {

    /// Tokens in the most recent context window.
    public let contextTokens: Int

    /// The model's context-window limit, in tokens.
    public let contextLimit: Int

    /// Total output tokens generated across the session.
    public let outputTokens: Int

    /// Estimated spend for the session, in US dollars.
    public let costUSD: Double

    /// The context window's fill level, clamped to `0...100`.
    public var contextPercent: Int {
        contextLimit > 0 ? min(100, Int(Double(contextTokens) / Double(contextLimit) * 100)) : 0
    }

    /// Creates a telemetry snapshot.
    public init(contextTokens: Int, contextLimit: Int, outputTokens: Int, costUSD: Double) {
        self.contextTokens = contextTokens
        self.contextLimit = contextLimit
        self.outputTokens = outputTokens
        self.costUSD = costUSD
    }
}
