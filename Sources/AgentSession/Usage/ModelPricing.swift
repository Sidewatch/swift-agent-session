import Foundation

/// Approximate per-million-token USD list prices by model family. Shared by the
/// per-session usage accumulator (``TranscriptState``) and the cross-project
/// aggregate (``UsageAggregator``) so a session's cost can never disagree with the
/// dashboard's total. Estimates — Anthropic's published list prices, cache tiers
/// included; the app labels cost as approximate.
enum ModelPricing {
    struct Rates { let input, cacheWrite, cacheRead, output: Double }

    static func rates(for model: String) -> Rates {
        let m = model.lowercased()
        if m.contains("opus")  { return Rates(input: 15, cacheWrite: 18.75, cacheRead: 1.5, output: 75) }
        if m.contains("haiku") { return Rates(input: 0.8, cacheWrite: 1.0, cacheRead: 0.08, output: 4) }
        return Rates(input: 3, cacheWrite: 3.75, cacheRead: 0.3, output: 15)   // sonnet / default
    }

    /// USD cost of one message's token usage under `model`'s rates.
    static func cost(model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int) -> Double {
        let r = rates(for: model)
        return Double(input) / 1e6 * r.input
             + Double(cacheWrite) / 1e6 * r.cacheWrite
             + Double(cacheRead) / 1e6 * r.cacheRead
             + Double(output) / 1e6 * r.output
    }
}
