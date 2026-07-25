//
//  TurnBoundary.swift
//  SwiftAgentSession
//
//  Splitting a flat timeline into agent turns — the run of events from one user prompt to
//  just before the next.
//
//  Created by David Sherlock on 7/25/26.
//

import Foundation

/// One agent turn: the run of timeline events from a user prompt up to just before the next.
///
/// A turn is the natural unit of review — "what did the agent do in response to what I asked" —
/// and the span a checkpoint pair brackets.
public struct TurnBoundary: Equatable {

    /// Index of the turn's opening `.userPrompt` event in the source timeline.
    public let start: Int

    /// Index of the turn's last event in the source timeline (inclusive).
    public let end: Int

    /// The prompt text that opened the turn, for labelling it.
    public let prompt: String

    /// The opening event's `HH:MM` timestamp, or `""` when unknown.
    public let timestamp: String

    /// Creates a turn boundary.
    ///
    /// - Parameters:
    ///   - start: Index of the opening `.userPrompt` event.
    ///   - end: Index of the final event in the turn.
    ///   - prompt: The opening prompt's text.
    ///   - timestamp: The opening event's timestamp.
    public init(start: Int, end: Int, prompt: String, timestamp: String) {
        self.start = start
        self.end = end
        self.prompt = prompt
        self.timestamp = timestamp
    }

    /// The number of events in the turn.
    public var count: Int { end - start + 1 }

    /// A stable identifier for the turn, derived from its opening prompt and timestamp.
    ///
    /// Must not be a position. Turns are re-derived on every poll, a transcript that rolls or
    /// replays re-points indices, and `TranscriptState` trims events from the FRONT once a
    /// session passes its cap — so every index shifts as a long session grows, which would
    /// orphan every persisted checkpoint. Must not be Swift's `hashValue` either: that is seeded
    /// per process and changes across relaunches. FNV-1a over the opening prompt and its
    /// timestamp is stable forever and already ref-name-safe.
    ///
    /// - Note: The prompt here is the event's `detail`, and the timestamp is only `HH:mm`, so two
    ///   turns opened by the SAME text within the same clock minute collapse to one id and share
    ///   a checkpoint — the later turn's diff would then start too early. Accepted deliberately:
    ///   the alternatives all reintroduce position, which is the worse failure. Fixing it
    ///   properly means carrying a full-precision timestamp on `TimelineEvent`.
    public var id: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array("\(timestamp)|\(prompt)".utf8) {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        return "turn-" + String(hash, radix: 16)
    }

    /// Splits a chronological timeline into turns, oldest first.
    ///
    /// Every `.userPrompt` opens a turn and closes the previous one. Events *before* the first
    /// prompt — a resumed session's replayed tail, or a transcript that simply starts mid-flow —
    /// belong to no turn and are dropped rather than folded into the first one, which would
    /// attribute work to a prompt that didn't cause it.
    ///
    /// - Parameter events: The timeline, oldest first.
    /// - Returns: The turns, oldest first. Empty when no prompt appears.
    public static func turns(in events: [TimelineEvent]) -> [TurnBoundary] {
        let starts = events.indices.filter { events[$0].kind == .userPrompt }
        guard !starts.isEmpty else { return [] }
        return starts.enumerated().map { position, start in
            // A turn runs to just before the next prompt, or to the end of the feed.
            let end = position + 1 < starts.count ? starts[position + 1] - 1 : events.count - 1
            return TurnBoundary(start: start, end: end,
                                prompt: events[start].detail, timestamp: events[start].timestamp)
        }
    }

    /// The turn containing the event at `index`, or `nil` when it precedes the first prompt.
    ///
    /// - Parameters:
    ///   - index: An index into the same timeline the turns were computed from.
    ///   - turns: The turns from ``turns(in:)``.
    /// - Returns: The enclosing turn, or `nil`.
    public static func turn(containing index: Int, in turns: [TurnBoundary]) -> TurnBoundary? {
        turns.last { $0.start <= index && index <= $0.end }
    }

    /// The distinct files edited during this turn, in first-touched order.
    ///
    /// - Parameter events: The timeline the turn indexes into.
    /// - Returns: Repo-relative paths, deduplicated.
    public func editedFiles(in events: [TimelineEvent]) -> [String] {
        guard start <= end, events.indices.contains(start), events.indices.contains(end) else { return [] }
        var seen = Set<String>()
        var files: [String] = []
        for event in events[start...end] where event.kind == .fileEdit {
            if let path = event.filePath, seen.insert(path).inserted { files.append(path) }
        }
        return files
    }
}
