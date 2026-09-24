//
//  TurnBoundary+Facts.swift
//  SwiftAgentSession
//
//  The facts a turn's own events carry beyond the files it edited: its effort and its plan.
//
//  Created by David Sherlock on 9/22/26.
//

import Foundation

extension TurnBoundary {

    /// The turn's effort from its events: tool calls, the last model seen, the summed cost.
    ///
    /// A message's cost is priced at the model its OWN event names, falling back to the last
    /// model seen in the turn and then to `ModelPricing`'s default, so a turn whose usage
    /// records precede their model name is still billed at the right generation.
    ///
    /// - Parameter events: The timeline the turn indexes into.
    /// - Returns: The effort, or ``TurnEffort/none`` when the turn's indices are not in `events`.
    public func effort(in events: [TimelineEvent]) -> TurnEffort {
        guard start <= end, events.indices.contains(start), events.indices.contains(end) else { return .none }
        var calls = 0, cost = 0.0
        var model: String? = nil
        for e in events[start...end] {
            if e.kind == .toolUse || e.kind == .fileEdit { calls += 1 }
            if let m = e.model { model = m }
            if let u = e.usage {
                cost += ModelPricing.cost(model: e.model ?? model ?? "claude", input: u.input, cacheWrite: u.cacheWrite,
                                          cacheRead: u.cacheRead, output: u.output)
            }
        }
        return TurnEffort(toolCalls: calls, model: model, cost: cost)
    }

}
