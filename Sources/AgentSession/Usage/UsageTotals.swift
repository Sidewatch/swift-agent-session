//
//  UsageTotals.swift
//  AgentSession
//
//  The running sums a usage report is built from, fed one record at a time.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// The running sums a usage report is built from, fed one record at a time.
struct UsageTotals {
    private var cost = 0.0, input = 0, output = 0, cacheRead = 0, cacheWrite = 0, messages = 0
    private var byModel: [String: UsageAggregator.Bucketing] = [:]
    private var byProject: [String: UsageAggregator.Bucketing] = [:]
    private var dailyCost: [String: Double] = [:]
    private var dailyTokens: [String: Int] = [:]
    private var sessionFiles = Set<String>()
    private var activeDays = Set<String>()
    private var hourCounts: [Int: Int] = [:]
    private var seenIDs = Set<String>()

    /// Adds one record; a duplicate response line (same id) is ignored.
    mutating func add(_ r: UsageRecord, project: String, file: URL) {
        if let id = r.id, !seenIDs.insert(id).inserted { return }
        cost += r.cost; input += r.input; cacheWrite += r.cacheWrite; cacheRead += r.cacheRead; output += r.output; messages += 1
        byModel[UsageAggregator.displayModel(r.model), default: .init()].add(cost: r.cost, i: r.input, o: r.output, cr: r.cacheRead, cw: r.cacheWrite)
        byProject[project, default: .init()].add(cost: r.cost, i: r.input, o: r.output, cr: r.cacheRead, cw: r.cacheWrite)
        sessionFiles.insert(file.path)
        if !r.day.isEmpty {
            dailyCost[r.day, default: 0] += r.cost
            dailyTokens[r.day, default: 0] += r.tokens
            activeDays.insert(r.day)
        }
        if let hour = r.localHour { hourCounts[hour, default: 0] += 1 }
    }

    func report(windowDays: Int?) -> UsageReport {
        let (current, longest) = UsageAggregator.streaks(activeDays)
        return UsageReport(
            totalCostUSD: cost, inputTokens: input, outputTokens: output,
            cacheReadTokens: cacheRead, cacheCreateTokens: cacheWrite, messageCount: messages,
            byModel: UsageAggregator.buckets(byModel), byProject: UsageAggregator.buckets(byProject),
            dailyCostUSD: dailyCost, windowDays: windowDays,
            dailyTokens: dailyTokens, sessionCount: sessionFiles.count, activeDays: activeDays.count,
            currentStreak: current, longestStreak: longest,
            peakHour: hourCounts.max { $0.value < $1.value }?.key)
    }
}
