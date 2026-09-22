//
//  TurnEffort+Display.swift
//  SwiftAgentSession
//
//  The short labels a row shows for a turn's effort: "opus 5", "$0.42".
//
//  Created by David Sherlock on 9/22/26.
//

import Foundation

extension TurnEffort {

    /// ``model`` as a row shows it: "opus 5", "sonnet 5", "haiku 4.5". `nil` when unknown.
    public var modelLabel: String? { Self.shortModel(model) }

    /// ``cost`` as a row shows it: "$0.42", "$12"; `nil` under half a cent.
    public var costLabel: String? { Self.costLabel(cost) }

    /// "opus 5", "sonnet 5", "haiku 4.5" — the family and version out of a model id.
    ///
    /// - Parameter id: A model id in either shape the transcripts use: `claude-opus-5`,
    ///   `claude-haiku-4-5-20251001`. The `claude-` prefix and a trailing date are dropped.
    /// - Returns: The family, then up to two numeric parts joined with a dot; `nil` for `nil`.
    public static func shortModel(_ id: String?) -> String? {
        guard let id else { return nil }
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-").map(String.init)
        guard let family = parts.first else { return nil }
        let version = parts.dropFirst().filter { $0.allSatisfy { $0.isNumber } }.prefix(2).joined(separator: ".")
        return version.isEmpty ? family : "\(family) \(version)"
    }

    /// "$0.42" under ten dollars, "$12" from ten up; `nil` under half a cent, so a row shows
    /// nothing rather than "$0.00".
    ///
    /// - Parameter cost: An estimated cost in USD.
    public static func costLabel(_ cost: Double) -> String? {
        guard cost >= 0.005 else { return nil }
        return String(format: cost >= 10 ? "$%.0f" : "$%.2f", cost)
    }
}
