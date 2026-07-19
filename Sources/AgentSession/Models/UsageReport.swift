import Foundation

/// A cross-session usage roll-up the dashboard renders — agent-neutral, so a future
/// adapter (Codex, …) can produce the same shape. Cost is estimated from approximate
/// list prices (``ModelPricing``); duplicate transcript lines for one API response are
/// counted once.
public struct UsageReport: Equatable {
    /// A cost/token subtotal for one grouping key (a model name or a project).
    public struct Bucket: Equatable {
        public let key: String
        public let costUSD: Double
        public let inputTokens: Int
        public let outputTokens: Int
        public let cacheReadTokens: Int
        public let cacheCreateTokens: Int
        public init(key: String, costUSD: Double, inputTokens: Int, outputTokens: Int,
                    cacheReadTokens: Int, cacheCreateTokens: Int) {
            self.key = key; self.costUSD = costUSD
            self.inputTokens = inputTokens; self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens; self.cacheCreateTokens = cacheCreateTokens
        }
    }

    public let totalCostUSD: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreateTokens: Int
    /// Distinct API responses counted.
    public let messageCount: Int
    /// Model subtotals, most-expensive first.
    public let byModel: [Bucket]
    /// Project subtotals, most-expensive first.
    public let byProject: [Bucket]
    /// Estimated cost per calendar day (`"yyyy-MM-dd"` → USD) for the heatmap.
    public let dailyCostUSD: [String: Double]
    /// Total tokens per calendar day (`"yyyy-MM-dd"` → tokens) for the Models chart.
    public let dailyTokens: [String: Int]
    /// The window this covers in days, or nil for all-time.
    public let windowDays: Int?

    /// Distinct transcript sessions (one `.jsonl` per Claude Code session).
    public let sessionCount: Int
    /// Distinct calendar days with any usage.
    public let activeDays: Int
    /// Consecutive active days ending today/yesterday (0 if the streak is broken).
    public let currentStreak: Int
    /// The longest run of consecutive active days ever.
    public let longestStreak: Int
    /// The local hour (0–23) with the most activity, or nil when there's none.
    public let peakHour: Int?

    /// Total tokens across every category (in + out + cache read + cache create).
    public var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreateTokens }
    /// The most-used model (top of `byModel`), or nil when there's no usage.
    public var favoriteModel: String? { byModel.first?.key }

    public init(totalCostUSD: Double, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                cacheCreateTokens: Int, messageCount: Int, byModel: [Bucket], byProject: [Bucket],
                dailyCostUSD: [String: Double], windowDays: Int?,
                dailyTokens: [String: Int] = [:], sessionCount: Int = 0, activeDays: Int = 0,
                currentStreak: Int = 0, longestStreak: Int = 0, peakHour: Int? = nil) {
        self.totalCostUSD = totalCostUSD
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreateTokens = cacheCreateTokens
        self.messageCount = messageCount
        self.byModel = byModel; self.byProject = byProject
        self.dailyCostUSD = dailyCostUSD; self.windowDays = windowDays
        self.dailyTokens = dailyTokens
        self.sessionCount = sessionCount; self.activeDays = activeDays
        self.currentStreak = currentStreak; self.longestStreak = longestStreak
        self.peakHour = peakHour
    }

    public static let empty = UsageReport(totalCostUSD: 0, inputTokens: 0, outputTokens: 0,
        cacheReadTokens: 0, cacheCreateTokens: 0, messageCount: 0, byModel: [], byProject: [],
        dailyCostUSD: [:], windowDays: nil)
}
