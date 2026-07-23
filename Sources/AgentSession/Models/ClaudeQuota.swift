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

    /// One window with the endpoint's key it arrived under (`"five_hour"`,
    /// `"seven_day_opus"`, `"seven_day_fable"`, …).
    public struct NamedWindow: Equatable {
        /// The endpoint's JSON key for this window.
        public let key: String
        /// The window's usage.
        public let window: Window

        public init(key: String, window: Window) {
            self.key = key
            self.window = window
        }
    }

    /// EVERY window the endpoint returned, in display order: the long-known keys
    /// first (5-hour, weekly, Opus, Sonnet), then anything new (per-model caps the
    /// endpoint grows — e.g. `seven_day_fable`) sorted by key. Parsing by shape
    /// rather than by a fixed key list is what keeps new model caps appearing
    /// without a code change.
    public let windows: [NamedWindow]

    /// The 5-hour session window.
    public var fiveHour: Window? { window("five_hour") }
    /// The 7-day (weekly) window across all models.
    public var sevenDay: Window? { window("seven_day") }
    /// The 7-day Opus-only cap (nil unless the plan has one active).
    public var sevenDayOpus: Window? { window("seven_day_opus") }
    /// The 7-day Sonnet-only cap (nil unless present).
    public var sevenDaySonnet: Window? { window("seven_day_sonnet") }

    /// The window stored under `key`, if the endpoint sent one.
    public func window(_ key: String) -> Window? {
        windows.first { $0.key == key }?.window
    }

    public init(windows: [NamedWindow]) {
        self.windows = windows
    }

    public init(fiveHour: Window?, sevenDay: Window?, sevenDayOpus: Window?, sevenDaySonnet: Window?) {
        var list: [NamedWindow] = []
        if let fiveHour { list.append(NamedWindow(key: "five_hour", window: fiveHour)) }
        if let sevenDay { list.append(NamedWindow(key: "seven_day", window: sevenDay)) }
        if let sevenDayOpus { list.append(NamedWindow(key: "seven_day_opus", window: sevenDayOpus)) }
        if let sevenDaySonnet { list.append(NamedWindow(key: "seven_day_sonnet", window: sevenDaySonnet)) }
        self.windows = list
    }

    /// True when at least one window was parsed — the gate for showing quota UI.
    public var hasAny: Bool { !windows.isEmpty }

    /// The known keys, shown first and in this order when present.
    private static let preferredOrder = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]

    /// Parses an `/api/oauth/usage` JSON body. Returns nil if the body isn't JSON or
    /// carries no recognizable window (so a 401/429/HTML error page fails soft).
    /// ANY top-level object with a numeric `utilization` counts as a window — the
    /// endpoint adds per-model caps over time (Opus, Sonnet, Fable, …) and they
    /// should surface without a parser change.
    public static func parse(_ data: Data) -> ClaudeQuota? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func window(_ value: Any) -> Window? {
            guard let w = value as? [String: Any],
                  let util = (w["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return Window(utilization: util, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
        }
        var list: [NamedWindow] = []
        for key in preferredOrder {
            if let v = obj[key], let w = window(v) { list.append(NamedWindow(key: key, window: w)) }
        }
        for key in obj.keys.sorted() where !preferredOrder.contains(key) {
            if let w = window(obj[key]!) { list.append(NamedWindow(key: key, window: w)) }
        }
        let q = ClaudeQuota(windows: list)
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
