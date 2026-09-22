//
//  TurnEffort.swift
//  SwiftAgentSession
//
//  What one agent turn cost: tool calls made, the model that answered, the estimated bill.
//
//  Created by David Sherlock on 9/22/26.
//

import Foundation

/// What one agent turn cost, summed from its events: the tool calls it made, the model that
/// answered (the last one seen in the turn), and the estimated cost from the messages' own
/// usage records at `ModelPricing`'s list prices.
///
/// Facts about effort, not a verdict on the work. A turn that made no tool call has
/// ``none``, and a host should show nothing for it rather than "0 tool calls".
public struct TurnEffort: Equatable, Sendable {

    /// Tool calls the turn made: every `.toolUse` and `.fileEdit` event.
    public let toolCalls: Int

    /// The model id that answered, as the transcript names it (`claude-opus-5`), or `nil` when
    /// no message in the turn carried one.
    public let model: String?

    /// The turn's estimated cost in USD, summed per message from its usage record.
    public let cost: Double

    /// Creates a turn's effort by hand — a host's own source, or a test.
    public init(toolCalls: Int, model: String?, cost: Double) {
        self.toolCalls = toolCalls
        self.model = model
        self.cost = cost
    }

    /// No tool calls, no model, no cost: the effort of a turn that only talked.
    public static let none = TurnEffort(toolCalls: 0, model: nil, cost: 0)
}
