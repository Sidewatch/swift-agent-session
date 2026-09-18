//
//  ClaudeQuota.swift
//  AgentSession
//
//  The current plan's rolling-window usage, as returned by Anthropic's internal
//  `/api/oauth/usage` endpoint (undocumented — see `ClaudeUsageQuota` app-side).
//
//  Created by David Sherlock on 7/19/26.
//

import Foundation

/// The current plan's rolling-window usage, as returned by Anthropic's internal
/// `/api/oauth/usage` endpoint (undocumented — see `ClaudeUsageQuota` app-side).
///
/// Two shapes are read. Since Sep 2026 the body carries a `limits` array — one row per cap with
/// `kind` (`session`, `weekly_all`, `weekly_scoped`), `percent`, `resets_at` and, for a scoped
/// weekly cap, `scope.model.display_name` — and that array is the source of truth when present:
/// the per-model weekly cap (Fable) lives ONLY there, the top-level `seven_day_<model>` keys
/// are null, and the top level also carries internal feature buckets under codenames that are
/// not limits. The older shape is the top-level windows alone, each with a **percent used**
/// `utilization` (0–100) and a reset time; it is still parsed when no `limits` array arrives.
/// Money against the monthly usage-credit cap comes from `spend` (or the older `extra_usage`),
/// and `seven_day_breakdown` says which surfaces used the week. Parsing is lenient: anything
/// that is not well-formed is dropped, never fatal.
public struct ClaudeQuota: Sendable, Equatable {

    /// One rolling window: how much of it is used, and when it resets.
    public struct Window: Sendable, Equatable {
        /// Percent of the window consumed, 0–100.
        public let utilization: Double
        /// When the window rolls over, if the endpoint provided it.
        public let resetsAt: Date?

        public init(utilization: Double, resetsAt: Date?) {
            self.utilization = utilization
            self.resetsAt = resetsAt
        }

        /// Percent used, clamped to 0–100 and rounded for display.
        public var percentUsed: Int { Int(min(100, max(0, utilization)).rounded()) }
        /// Percent remaining (100 − used).
        public var percentRemaining: Int { 100 - percentUsed }
    }

    /// One window with the endpoint's key it arrived under (`"five_hour"`,
    /// `"seven_day_opus"`, `"seven_day_fable"`, …).
    public struct NamedWindow: Sendable, Equatable {
        /// The endpoint's JSON key for this window.
        public let key: String
        /// The window's usage.
        public let window: Window

        public init(key: String, window: Window) {
            self.key = key
            self.window = window
        }
    }

    /// Money spent against the monthly usage-credit cap, in the account's own currency and
    /// minor units (pence, cents): `usedMinor` of `limitMinor`, `exponent` decimal places.
    public struct Spend: Sendable, Equatable {
        public let usedMinor: Int
        public let limitMinor: Int
        /// ISO 4217 code (`GBP`, `USD`, `EUR`).
        public let currency: String
        /// Decimal places of the currency (2 for the three above).
        public let exponent: Int
        /// Percent of the cap used, 0–100.
        public let percent: Int

        public init(usedMinor: Int, limitMinor: Int, currency: String, exponent: Int, percent: Int) {
            self.usedMinor = usedMinor
            self.limitMinor = limitMinor
            self.currency = currency
            self.exponent = exponent
            self.percent = percent
        }
    }

    /// One surface's share of the week (`Claude Code` 98, `Chats` 2).
    public struct Share: Sendable, Equatable {
        public let name: String
        public let percent: Int

        public init(name: String, percent: Int) {
            self.name = name
            self.percent = percent
        }
    }

    /// EVERY limit the endpoint returned, in display order. From a `limits` array: the rows in
    /// the endpoint's order, keyed `session`, `weekly_all`, `weekly_scoped:<Name>`. From the
    /// older top-level shape: the long-known keys first (5-hour, weekly, Opus, Sonnet), then
    /// anything new (`seven_day_fable`, …) sorted by key — parsing by shape rather than by a
    /// fixed key list is what kept new model caps appearing without a code change.
    public let windows: [NamedWindow]
    /// Usage-credit spend this month, when the account has credits enabled.
    public let spend: Spend?
    /// Which surfaces used the week, non-zero shares only, in the endpoint's order.
    public let weekShares: [Share]

    /// The 5-hour session window.
    public var fiveHour: Window? { window("five_hour") ?? window("session") }
    /// The 7-day (weekly) window across all models.
    public var sevenDay: Window? { window("seven_day") ?? window("weekly_all") }
    /// The 7-day Opus-only cap (nil unless the plan has one active).
    public var sevenDayOpus: Window? { window("seven_day_opus") ?? window("weekly_scoped:Opus") }
    /// The 7-day Sonnet-only cap (nil unless present).
    public var sevenDaySonnet: Window? { window("seven_day_sonnet") ?? window("weekly_scoped:Sonnet") }

    /// The window stored under `key`, if the endpoint sent one.
    public func window(_ key: String) -> Window? {
        windows.first { $0.key == key }?.window
    }

    public init(windows: [NamedWindow], spend: Spend? = nil, weekShares: [Share] = []) {
        self.windows = windows
        self.spend = spend
        self.weekShares = weekShares
    }

    public init(fiveHour: Window?, sevenDay: Window?, sevenDayOpus: Window?, sevenDaySonnet: Window?) {
        var list: [NamedWindow] = []
        if let fiveHour { list.append(NamedWindow(key: "five_hour", window: fiveHour)) }
        if let sevenDay { list.append(NamedWindow(key: "seven_day", window: sevenDay)) }
        if let sevenDayOpus { list.append(NamedWindow(key: "seven_day_opus", window: sevenDayOpus)) }
        if let sevenDaySonnet { list.append(NamedWindow(key: "seven_day_sonnet", window: sevenDaySonnet)) }
        self.windows = list
        self.spend = nil
        self.weekShares = []
    }

    /// True when at least one limit or a spend figure was parsed — the gate for showing quota UI.
    public var hasAny: Bool { !windows.isEmpty || spend != nil }

    /// The known keys, shown first and in this order when present.
    private static let preferredOrder = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    /// Parses an `/api/oauth/usage` JSON body. Returns nil if the body isn't JSON or carries
    /// neither a limit nor a spend figure (so a 401/429/HTML error page fails soft). The
    /// `limits` array wins when present; otherwise ANY top-level object with a numeric
    /// `utilization` counts as a window, `extra_usage` excepted — that one is the spend.
    public static func parse(_ data: Data) -> ClaudeQuota? {
        guard let obj = JSONFile.object(from: data) else { return nil }
        let windows = limitWindows(obj["limits"]) ?? legacyWindows(obj)
        let spend = Spend.parse(obj["spend"]) ?? Spend.parse(extraUsage: obj["extra_usage"])
        let q = ClaudeQuota(windows: windows, spend: spend, weekShares: shares(obj["seven_day_breakdown"]))
        return q.hasAny ? q : nil
    }

    /// The `limits` rows as windows: `kind` is the key, a scoped weekly cap appends the scope's
    /// model (or surface) name — `weekly_scoped:Fable`. Nil when there is no usable array, so
    /// the caller falls back to the older shape.
    static func limitWindows(_ value: Any?) -> [NamedWindow]? {
        guard let rows = value as? [[String: Any]] else { return nil }
        var list: [NamedWindow] = []
        for row in rows {
            guard let kind = row["kind"] as? String,
                  let percent = (row["percent"] as? NSNumber)?.doubleValue else { continue }
            var key = kind
            if kind == "weekly_scoped", let scope = row["scope"] as? [String: Any] {
                let model = (scope["model"] as? [String: Any])?["display_name"] as? String
                let surface = (scope["surface"] as? [String: Any])?["display_name"] as? String
                    ?? scope["surface"] as? String
                if let name = model ?? surface { key = "weekly_scoped:\(name)" }
            }
            let resets = (row["resets_at"] as? String).flatMap(parseDate)
            list.append(NamedWindow(key: key, window: Window(utilization: percent, resetsAt: resets)))
        }
        return list.isEmpty ? nil : list
    }

    /// The pre-`limits` shape: top-level windows, known keys first, then the rest by key.
    static func legacyWindows(_ obj: [String: Any]) -> [NamedWindow] {
        func window(_ value: Any) -> Window? {
            guard let w = value as? [String: Any],
                  let util = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Window(utilization: util, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
        }
        var list: [NamedWindow] = []
        for key in preferredOrder {
            if let v = obj[key], let w = window(v) { list.append(NamedWindow(key: key, window: w)) }
        }
        for key in obj.keys.sorted() where !preferredOrder.contains(key) && key != "extra_usage" {
            if let w = window(obj[key]!) { list.append(NamedWindow(key: key, window: w)) }
        }
        return list
    }

    /// `seven_day_breakdown.rows` with a non-zero percent, in the endpoint's order.
    static func shares(_ value: Any?) -> [Share] {
        guard let b = value as? [String: Any], let rows = b["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let name = row["display_name"] as? String ?? row["key"] as? String,
                  let percent = (row["percent"] as? NSNumber)?.intValue, percent > 0 else { return nil }
            return Share(name: name, percent: percent)
        }
    }

    /// String convenience for the parser (used by the `--dump-quota` diagnostic).
    public static func parse(_ json: String) -> ClaudeQuota? {
        parse(Data(json.utf8))
    }

    /// Parses the endpoint's ISO-8601 `resets_at`, which carries **microsecond**
    /// fractional seconds (`…:00.528743+00:00`) that `.withFractionalSeconds`
    /// (millisecond-only) rejects — so it falls back to stripping the fraction.
    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        // Strip the fractional seconds (from "." up to the timezone) and retry.
        if let dot = s.firstIndex(of: "."),
           let tz = s[s.index(after: dot)...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            return iso.date(from: String(s[..<dot]) + String(s[tz...]))
        }
        return nil
    }
}

extension ClaudeQuota.Spend {
    /// The `spend` object: `used` / `limit` as `{amount_minor, currency, exponent}`, plus
    /// `percent` and `enabled`. Nil when disabled or malformed.
    static func parse(_ value: Any?) -> ClaudeQuota.Spend? {
        guard let s = value as? [String: Any], (s["enabled"] as? Bool) != false,
              let used = s["used"] as? [String: Any], let limit = s["limit"] as? [String: Any],
              let usedMinor = (used["amount_minor"] as? NSNumber)?.intValue,
              let limitMinor = (limit["amount_minor"] as? NSNumber)?.intValue,
              let currency = used["currency"] as? String else { return nil }
        let exponent = (used["exponent"] as? NSNumber)?.intValue ?? 2
        let percent = (s["percent"] as? NSNumber)?.intValue ?? ratio(usedMinor, limitMinor)
        return ClaudeQuota.Spend(usedMinor: usedMinor, limitMinor: limitMinor, currency: currency,
                                 exponent: exponent, percent: percent)
    }

    /// The older `extra_usage` object: `used_credits` / `monthly_limit` already in minor units,
    /// `currency`, `decimal_places`, `utilization`. Nil unless `is_enabled`.
    static func parse(extraUsage value: Any?) -> ClaudeQuota.Spend? {
        guard let e = value as? [String: Any], e["is_enabled"] as? Bool == true,
              let used = (e["used_credits"] as? NSNumber)?.doubleValue,
              let limit = (e["monthly_limit"] as? NSNumber)?.doubleValue,
              let currency = e["currency"] as? String else { return nil }
        let usedMinor = Int(used.rounded()), limitMinor = Int(limit.rounded())
        let percent = (e["utilization"] as? NSNumber).map { Int($0.doubleValue.rounded()) } ?? ratio(usedMinor, limitMinor)
        return ClaudeQuota.Spend(usedMinor: usedMinor, limitMinor: limitMinor, currency: currency,
                                 exponent: (e["decimal_places"] as? NSNumber)?.intValue ?? 2, percent: percent)
    }

    private static func ratio(_ used: Int, _ limit: Int) -> Int {
        limit > 0 ? Int((Double(used) / Double(limit) * 100).rounded()) : 0
    }
}
