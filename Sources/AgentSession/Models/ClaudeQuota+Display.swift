//
//  ClaudeQuota+Display.swift
//  AgentSession
//
//  The window's display name: `five_hour` is the 5-hour session, `seven_day` is Weekly, a per-
//  model weekly cap is `Weekly · Model`, and an unknown key reads as its words.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

extension ClaudeQuota.NamedWindow {
    /// The window's display name: `five_hour` is the 5-hour session, `seven_day` is Weekly,
    /// a per-model weekly cap is `Weekly · Model`, and an unknown key reads as its words.
    public var label: String {
        switch key {
        case "five_hour", "session": return "5-hour session"
        case "seven_day": return "Weekly"
        case "weekly_all": return "Weekly · all models"
        default:
            if key.hasPrefix("weekly_scoped:") {
                return "Weekly · \(key.dropFirst("weekly_scoped:".count))"
            }
            if key.hasPrefix("seven_day_") {
                return "Weekly · \(key.dropFirst("seven_day_".count).replacingOccurrences(of: "_", with: " ").capitalized)"
            }
            return key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

extension ClaudeQuota.Window {
    /// When the window rolls over, in words: `resets in 1d 2h`, `resets in 1h 30m`,
    /// `resets in 5m`, `resets now`. Nil when the endpoint gave no reset time.
    public func resetDescription(now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let secs = Int(resetsAt.timeIntervalSince(now))
        if secs <= 0 { return "resets now" }
        let h = secs / 3600, m = (secs % 3600) / 60
        if h >= 24 { return "resets in \(h / 24)d \(h % 24)h" }
        if h > 0 { return "resets in \(h)h \(m)m" }
        return "resets in \(m)m"
    }
}

extension ClaudeQuota.Spend {
    /// `£12.34 of £100.00` — both amounts in the account's currency. Formatted in a fixed
    /// locale so GBP, USD and EUR read as `£`, `$`, `€` on every Mac.
    public var summary: String { "\(formatted(usedMinor)) of \(formatted(limitMinor))" }

    /// One amount in minor units as currency text.
    public func formatted(_ minor: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = currency
        f.locale = Locale(identifier: "en_US")
        f.minimumFractionDigits = exponent
        f.maximumFractionDigits = exponent
        let value = Decimal(minor) / pow(Decimal(10), exponent)
        return f.string(from: value as NSDecimalNumber) ?? "\(value) \(currency)"
    }
}
