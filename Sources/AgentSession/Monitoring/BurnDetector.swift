//
//  BurnDetector.swift
//  AgentSession
//
//  "The agent is stuck": the same tool call repeated as the most recent consecutive calls
//  of a transcript, tracked as an episode that fires once and refreshes its count.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// Loop detection over a transcript's timeline. Feed it the events on every tick that saw
/// new activity; it answers with what changed — a new episode, a refreshed count, the end
/// of an episode, or nothing — and the host decides how to show it (a badge, a status line).
///
/// The rule: the same normalised command `threshold` or more times as *consecutive* tool
/// calls ending at the most recent one (the loop is live, not history). Only `.toolUse`
/// events participate — `.fileEdit` is routine work (three edits to one file is the normal
/// multi-hunk pattern) and breaks the run, as does any distinct tool call or a user prompt;
/// assistant prose and empty-detail bookkeeping calls (TodoWrite-style) are skipped.
public struct BurnDetector: Sendable, Equatable {

    /// What one `update` changed.
    public enum Verdict: Equatable, Sendable {
        /// A loop started: the notice to show, e.g. `agent may be looping: swift build ×3`.
        case started(notice: String)
        /// The same loop is still going and its count changed; the notice carries the new count.
        case updated(notice: String)
        /// The episode ended (distinct activity, a user prompt, or the transcript settled).
        case ended
        /// Nothing to report.
        case none
    }

    /// How many recent events are examined.
    public var window: Int
    /// How many consecutive repeats make a loop.
    public var threshold: Int
    /// The looping command's key while an episode is live.
    public private(set) var signalledKey: String?
    /// The episode's last reported repeat count.
    public private(set) var signalledCount = 0

    public init(window: Int = 15, threshold: Int = 3) {
        self.window = window
        self.threshold = threshold
    }

    /// True while an episode is live.
    public var isLooping: Bool { signalledKey != nil }

    /// Normalises a tool event for loop detection — tool name plus the WHOLE command with its
    /// whitespace collapsed (capped, so a pasted file does not make every key unique) — or
    /// nil for bookkeeping calls whose detail is empty, which never participate. The label is
    /// the command's first line, for a status line.
    ///
    /// Keyed on the first line alone until 5 Sep 2026, which flagged a Claude Code session
    /// whose scripted commands all began with the same `cd …; python3 - <<'EOF'` line and
    /// differed entirely below it. Three different commands are not a loop.
    public static func key(for event: TimelineEvent) -> (key: String, label: String)? {
        let line = event.detail.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? event.detail
        let label = line.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        let whole = event.detail.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ").prefix(2000)
        return ("\(event.title)|\(whole)", label)
    }

    /// Examines the tail of `events` and moves the episode state accordingly.
    public mutating func update(events: [TimelineEvent]) -> Verdict {
        var latest: (key: String, label: String)?
        var count = 0
        scan: for event in events.suffix(window).reversed() {
            switch event.kind {
            case .assistantText:
                continue                                        // prose between repeats does not break a live loop
            case .userPrompt, .fileEdit:
                break scan                                      // distinct work or user intervention: the run ends here
            case .toolUse:
                guard let candidate = Self.key(for: event) else { continue }   // bookkeeping: skip
                if latest == nil { latest = candidate }
                guard latest?.key == candidate.key else { break scan }         // a distinct tool call
                count += 1
            }
        }
        guard let latest, count >= threshold else {
            guard signalledKey != nil else { return .none }
            signalledKey = nil
            signalledCount = 0
            return .ended
        }
        let notice = "agent may be looping: \(latest.label) ×\(count)"
        if signalledKey == latest.key {
            guard count != signalledCount else { return .none }
            signalledCount = count
            return .updated(notice: notice)
        }
        signalledKey = latest.key
        signalledCount = count
        return .started(notice: notice)
    }

    /// Forgets the current episode (a session or root reset).
    public mutating func reset() {
        signalledKey = nil
        signalledCount = 0
    }
}
