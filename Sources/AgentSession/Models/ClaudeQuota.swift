import Foundation

/// The current plan's rolling-window usage, as returned by Anthropic's internal
/// `/api/oauth/usage` endpoint (undocumented — see `ClaudeUsageQuota` app-side).
///
/// Each window reports `utilization` as a **percent used** (0–100), plus when it
/// resets. `seven_day_opus` / `seven_day_sonnet` are the per-model weekly caps and
/// are often absent/null. Parsing is lenient: any window that isn't a well-formed
/// object with a numeric `utilization` is simply dropped.
public struct ClaudeQuota: Equatable {

    /// One rolling window: how much of it is used, and when it resets.
    public struct Window: Equatable {
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

    /// The 5-hour session window.
    public let fiveHour: Window?
    /// The 7-day (weekly) window across all models.
    public let sevenDay: Window?
    /// The 7-day Opus-only cap (nil unless the plan has one active).
    public let sevenDayOpus: Window?
    /// The 7-day Sonnet-only cap (nil unless present).
    public let sevenDaySonnet: Window?

    public init(fiveHour: Window?, sevenDay: Window?, sevenDayOpus: Window?, sevenDaySonnet: Window?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayOpus = sevenDayOpus
        self.sevenDaySonnet = sevenDaySonnet
    }

    /// True when at least one window was parsed — the gate for showing quota UI.
    public var hasAny: Bool {
        fiveHour != nil || sevenDay != nil || sevenDayOpus != nil || sevenDaySonnet != nil
    }

    /// Parses an `/api/oauth/usage` JSON body. Returns nil if the body isn't JSON or
    /// carries no recognizable window (so a 401/429/HTML error page fails soft).
    public static func parse(_ data: Data) -> ClaudeQuota? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func window(_ key: String) -> Window? {
            guard let w = obj[key] as? [String: Any],
                  let util = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Window(utilization: util, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
        }
        let q = ClaudeQuota(fiveHour: window("five_hour"), sevenDay: window("seven_day"),
                            sevenDayOpus: window("seven_day_opus"), sevenDaySonnet: window("seven_day_sonnet"))
        return q.hasAny ? q : nil
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
