//
//  UsageAggregator.swift
//  AgentSession
//
//  Rolls up token/cost usage across *every* Claude Code project transcript under
//  `~/.claude/projects/*/*.jsonl` — the data behind the Usage tab's local half.
//
//  Created by David Sherlock on 7/19/26.
//

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
        var totals = UsageTotals()
        for (project, file) in transcriptFiles(in: projectsRoot, modifiedOnOrAfter: cutoffDay) {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
            for lineData in splitLines(data) where lineData.range(of: usageMarker) != nil {   // cheap gate: only usage-bearing lines are worth parsing
                guard let record = UsageRecord(line: lineData), record.tokens > 0 else { continue }
                if let cutoffDay, !record.day.isEmpty, record.day < cutoffDay { continue }
                totals.add(record, project: project, file: file)
            }
        }
        return totals.report(windowDays: windowDays)
    }

    /// Every `.jsonl` transcript under `projectsRoot`, with its project's display name — skipping
    /// files untouched since before the window (turns a full-history scan into an O(window) one).
    private static func transcriptFiles(in projectsRoot: URL, modifiedOnOrAfter cutoffDay: String?) -> [(project: String, file: URL)] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, URL)] = []
        for dir in projectDirs where dir.isExistingDirectory {
            let project = projectName(fromEncoded: dir.lastPathComponent)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                if let cutoffDay, let mod = file.modificationDate, dayString(mod) < cutoffDay { continue }
                out.append((project, file))
            }
        }
        return out
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

    struct Bucketing {
        var cost = 0.0, i = 0, o = 0, cr = 0, cw = 0
        mutating func add(cost c: Double, i ai: Int, o ao: Int, cr acr: Int, cw acw: Int) {
            cost += c; i += ai; o += ao; cr += acr; cw += acw
        }
    }
    static func buckets(_ d: [String: Bucketing]) -> [UsageReport.Bucket] {
        d.map { UsageReport.Bucket(key: $0.key, costUSD: $0.value.cost, inputTokens: $0.value.i,
                                   outputTokens: $0.value.o, cacheReadTokens: $0.value.cr,
                                   cacheCreateTokens: $0.value.cw) }
         .sorted { $0.costUSD > $1.costUSD }
    }

    // MARK: - Helpers

    /// `{"…"usage"…}` marker bytes for the pre-filter.
    static let usageMarker = Data("\"usage\"".utf8)

    /// Splits mmap'd JSONL into per-line `Data` slices (no String allocation).
    static func splitLines(_ data: Data) -> [Data] {
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
        // en_US_POSIX pins ASCII digits — the output is compared lexicographically
        // against ASCII days from JSONL timestamps, so a locale whose numbering
        // system is non-Latin (ar_EG, fa_IR, …) would filter out every line.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        return f
    }()
    /// `"yyyy-MM-dd"` for a date.
    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    /// `"yyyy-MM-dd"` for N days before today (local calendar).
    static func dayString(daysAgo: Int) -> String {
        dayString(Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date())
    }

    /// Claude Code encodes a project's cwd as `[^A-Za-z0-9]→-`; the original path
    /// isn't recoverable, but the last non-empty segment is the folder name.
    static func projectName(fromEncoded encoded: String) -> String {
        let segments = encoded.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        return segments.last ?? encoded
    }

    /// A short model label ("claude-opus-4-…" → "Opus 4", else the family word).
    static func displayModel(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("opus")  { return "Opus" }
        if m.contains("sonnet") { return "Sonnet" }
        if m.contains("haiku") { return "Haiku" }
        if m.contains("fable") { return "Fable" }
        return model
    }
}
