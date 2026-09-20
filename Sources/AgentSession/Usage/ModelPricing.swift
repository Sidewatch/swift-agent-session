//
//  ModelPricing.swift
//  AgentSession
//
//  Per-million-token USD list prices by model family and generation.
//
//  Created by David Sherlock on 7/19/26.
//

import Foundation

/// Per-million-token USD list prices by model family and generation, from Anthropic's published
/// pricing page (platform.claude.com/docs/en/about-claude/pricing, read 18 Sep 2026). Shared by
/// the per-session usage accumulator (``TranscriptState``) and the cross-project aggregate
/// (``UsageAggregator``) so a session's cost can never disagree with the dashboard's total.
///
/// Estimates: list prices at the 5-minute cache-write tier, no batch or volume discount, and a
/// subscription plan is not billed per token at all — the number is what the same tokens would
/// cost at API list prices. The app labels every cost as approximate.
///
/// The generation is read from the id (`claude-opus-4-8`, `claude-haiku-4-5-20251001`,
/// `claude-3-5-sonnet-20241022`): its short numeric parts, in order. Prices changed at fixed
/// points — Opus and Haiku at 4.5, Sonnet at 5, Fable's cache read at 5.1 — and an id with no
/// version at all is charged its family's older rates, the only honest reading of a string that
/// says nothing about which one it is.
public enum ModelPricing {
    struct Rates: Equatable { let input, cacheWrite, cacheRead, output: Double }

    static func rates(for model: String) -> Rates {
        let m = model.lowercased()
        let v = generation(of: m)
        if m.contains("fable") || m.contains("mythos") {
            // 5.1 reads its cache at 0.025× the input price ($0.25); 5.0 at the standard 0.1× ($1).
            return atLeast(v, 5, 1) ? Rates(input: 10, cacheWrite: 12.5, cacheRead: 0.25, output: 50)
                                    : Rates(input: 10, cacheWrite: 12.5, cacheRead: 1, output: 50)
        }
        if m.contains("opus") {
            return atLeast(v, 4, 5) ? Rates(input: 5, cacheWrite: 6.25, cacheRead: 0.5, output: 25)
                                    : Rates(input: 15, cacheWrite: 18.75, cacheRead: 1.5, output: 75)
        }
        if m.contains("haiku") {
            return atLeast(v, 4, 5) ? Rates(input: 1, cacheWrite: 1.25, cacheRead: 0.1, output: 5)
                                    : Rates(input: 0.8, cacheWrite: 1, cacheRead: 0.08, output: 4)
        }
        // Sonnet, and the default for a family this table does not know.
        return atLeast(v, 5, 0) ? Rates(input: 2, cacheWrite: 2.5, cacheRead: 0.2, output: 10)
                                : Rates(input: 3, cacheWrite: 3.75, cacheRead: 0.3, output: 15)
    }

    /// `(major, minor)` from the id's short numeric parts — `claude-opus-4-8` → 4.8,
    /// `claude-opus-5` → 5.0, `claude-3-5-sonnet-20241022` → 3.5 — or nil when it carries none.
    /// An 8-digit date is not a version.
    static func generation(of model: String) -> (major: Int, minor: Int)? {
        let numbers = model.split(whereSeparator: { !$0.isNumber }).filter { $0.count <= 2 }.compactMap { Int($0) }
        guard let major = numbers.first else { return nil }
        return (major, numbers.count > 1 ? numbers[1] : 0)
    }

    private static func atLeast(_ v: (major: Int, minor: Int)?, _ major: Int, _ minor: Int) -> Bool {
        guard let v else { return false }
        return v.major > major || (v.major == major && v.minor >= minor)
    }

    /// USD cost of one message's token usage under `model`'s rates.
    public static func cost(model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int) -> Double {
        let r = rates(for: model)
        return Double(input) / 1e6 * r.input
             + Double(cacheWrite) / 1e6 * r.cacheWrite
             + Double(cacheRead) / 1e6 * r.cacheRead
             + Double(output) / 1e6 * r.output
    }
}
