import Foundation

/// Rolls up token/cost usage across *every* Claude Code project transcript under
/// `~/.claude/projects/*/*.jsonl` — the data behind the Usage tab's local half.
///
/// Reads only lines that mention `"usage"` (a cheap byte-substring pre-filter skips the
/// vast majority — user/tool lines) then JSON-parses those, dedups by `message.id`, and
/// buckets by model, project, and calendar day. Read-only; costs an estimate.
public enum UsageAggregator {

    /// The real `~/.claude/projects` container.
    public static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Aggregates usage across all projects. `windowDays` limits to the last N days by
    /// each message's `timestamp` (nil = all-time). Call off the main thread — a heavy
    /// history is many megabytes to scan.
    public static func report(projectsRoot: URL = defaultProjectsRoot, windowDays: Int? = nil) -> UsageReport {
        let cutoffDay = windowDays.map { dayString(daysAgo: $0) }

        var totalCost = 0.0, inTok = 0, outTok = 0, crTok = 0, cwTok = 0, msgs = 0
        var modelCost: [String: Bucketing] = [:]
        var projectCost: [String: Bucketing] = [:]
        var dailyCost: [String: Double] = [:]
        var dailyTokens: [String: Int] = [:]
        var sessionFiles = Set<String>()
        var activeDaySet = Set<String>()
        var hourCounts = [Int: Int]()
        let tzOffsetHours = TimeZone.current.secondsFromGMT() / 3600
        var seenIDs = Set<String>()

        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else {
            return .empty
        }
        for dir in projectDirs {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let project = projectName(fromEncoded: dir.lastPathComponent)
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for file in files where file.pathExtension == "jsonl" {
                // Windowed query: a file untouched since before the window holds no data
                // in it — skip without reading (turns a full-history scan into an O(window)
                // one for the common 7-/30-day views).
                if let cutoffDay,
                   let mod = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                   dayString(mod) < cutoffDay { continue }
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                for lineData in splitLines(data) {
                    // Cheap gate: only usage-bearing lines are worth JSON-parsing.
                    guard lineData.range(of: usageMarker) != nil else { continue }
                    guard let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                          let msg = obj["message"] as? [String: Any],
                          let usage = msg["usage"] as? [String: Any] else { continue }

                    // Day / window filter (timestamp is ISO8601; the day is its first 10 chars).
                    let day = (obj["timestamp"] as? String).map { String($0.prefix(10)) } ?? ""
                    if let cutoffDay, !day.isEmpty, day < cutoffDay { continue }

                    let id = (msg["id"] as? String) ?? (obj["requestId"] as? String)
                    if let id, !seenIDs.insert(id).inserted { continue }   // duplicate response line

                    let model = (msg["model"] as? String).flatMap { $0.isEmpty || $0 == "<synthetic>" ? nil : $0 } ?? "unknown"
                    let inp = usage["input_tokens"] as? Int ?? 0
                    let cw = usage["cache_creation_input_tokens"] as? Int ?? 0
                    let cr = usage["cache_read_input_tokens"] as? Int ?? 0
                    let out = usage["output_tokens"] as? Int ?? 0
                    guard inp + cw + cr + out > 0 else { continue }
                    let cost = ModelPricing.cost(model: model, input: inp, cacheWrite: cw, cacheRead: cr, output: out)

                    totalCost += cost; inTok += inp; cwTok += cw; crTok += cr; outTok += out; msgs += 1
                    modelCost[displayModel(model), default: .init()].add(cost: cost, i: inp, o: out, cr: cr, cw: cw)
                    projectCost[project, default: .init()].add(cost: cost, i: inp, o: out, cr: cr, cw: cw)
                    sessionFiles.insert(file.path)
                    if !day.isEmpty {
                        dailyCost[day, default: 0] += cost
                        dailyTokens[day, default: 0] += inp + cw + cr + out
                        activeDaySet.insert(day)
                    }
                    // Peak local hour from the ISO timestamp's UTC hour (chars 11–12).
                    if let ts = obj["timestamp"] as? String, ts.count >= 13,
                       let utcHour = Int(ts.dropFirst(11).prefix(2)) {
                        hourCounts[((utcHour + tzOffsetHours) % 24 + 24) % 24, default: 0] += 1
                    }
                }
            }
        }

        let (current, longest) = streaks(activeDaySet)
        return UsageReport(
            totalCostUSD: totalCost, inputTokens: inTok, outputTokens: outTok,
            cacheReadTokens: crTok, cacheCreateTokens: cwTok, messageCount: msgs,
            byModel: buckets(modelCost), byProject: buckets(projectCost),
            dailyCostUSD: dailyCost, windowDays: windowDays,
            dailyTokens: dailyTokens, sessionCount: sessionFiles.count, activeDays: activeDaySet.count,
            currentStreak: current, longestStreak: longest,
            peakHour: hourCounts.max { $0.value < $1.value }?.key)
    }

    /// Current + longest consecutive-active-day streaks from a set of `yyyy-MM-dd`
    /// days. Current counts only if the last active day is today or yesterday.
    static func streaks(_ days: Set<String>) -> (current: Int, longest: Int) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        let nums = days.compactMap { f.date(from: $0) }
            .map { Int($0.timeIntervalSince1970 / 86400) }.sorted()
        guard let last = nums.last else { return (0, 0) }

        var longest = 1, run = 1
        for i in 1..<max(1, nums.count) {
            if nums[i] == nums[i - 1] + 1 { run += 1 } else if nums[i] != nums[i - 1] { run = 1 }
            longest = max(longest, run)
        }
        // Compute "today" through the SAME local-midnight pipeline as the day set,
        // so the day numbers are comparable regardless of timezone.
        let today = f.date(from: f.string(from: Date())).map { Int($0.timeIntervalSince1970 / 86400) } ?? last
        var current = 0
        if last == today || last == today - 1 {
            current = 1
            var idx = nums.count - 2
            while idx >= 0, nums[idx] == nums[idx + 1] - 1 { current += 1; idx -= 1 }
        }
        return (current, longest)
    }

    // MARK: - Accumulation

    private struct Bucketing {
        var cost = 0.0, i = 0, o = 0, cr = 0, cw = 0
        mutating func add(cost c: Double, i ai: Int, o ao: Int, cr acr: Int, cw acw: Int) {
            cost += c; i += ai; o += ao; cr += acr; cw += acw
        }
    }
    private static func buckets(_ d: [String: Bucketing]) -> [UsageReport.Bucket] {
        d.map { UsageReport.Bucket(key: $0.key, costUSD: $0.value.cost, inputTokens: $0.value.i,
                                   outputTokens: $0.value.o, cacheReadTokens: $0.value.cr,
                                   cacheCreateTokens: $0.value.cw) }
         .sorted { $0.costUSD > $1.costUSD }
    }

    // MARK: - Helpers

    /// `{"…"usage"…}` marker bytes for the pre-filter.
    private static let usageMarker = Data("\"usage\"".utf8)

    /// Splits mmap'd JSONL into per-line `Data` slices (no String allocation).
    private static func splitLines(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        let nl: UInt8 = 0x0A
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == nl {
                if i > start { lines.append(data.subdata(in: start..<i)) }
                start = data.index(after: i)
            }
            i = data.index(after: i)
        }
        if start < data.endIndex { lines.append(data.subdata(in: start..<data.endIndex)) }
        return lines
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = Calendar(identifier: .gregorian); return f
    }()
    /// `"yyyy-MM-dd"` for a date.
    private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// `"yyyy-MM-dd"` for N days before today (local calendar).
    private static func dayString(daysAgo: Int) -> String {
        dayString(Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date())
    }

    /// Claude Code encodes a project's cwd as `[^A-Za-z0-9]→-`; the original path
    /// isn't recoverable, but the last non-empty segment is the folder name.
    private static func projectName(fromEncoded encoded: String) -> String {
        let segments = encoded.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        return segments.last ?? encoded
    }

    /// A short model label ("claude-opus-4-…" → "Opus 4", else the family word).
    private static func displayModel(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus")  { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        if m.contains("fable") { return "Fable" }
        return model
    }
}
