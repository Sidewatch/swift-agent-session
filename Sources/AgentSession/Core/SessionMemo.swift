//
//  SessionMemo.swift
//  SwiftAgentSession
//
//  Time-bounded memoization for adapters with no append-only log to tail.
//
//  Created by David Sherlock on 7/26/26.
//

import Foundation

/// A tiny time-bounded memo for adapters whose sessions are directory trees.
///
/// Claude and Codex stream an append-only log, so `TranscriptCache` makes a poll cost one stat.
/// OpenCode and Gemini have no tail to read: locating a session means walking directories and
/// reading marker/head files, and parsing means re-reading every message file. The timeline polls
/// every 2s and asks for events AND summary, so without this each tick paid for the whole tree
/// two or three times over.
///
/// Deliberately time-bounded rather than invalidated: these adapters have no cheap change signal,
/// and a second of staleness in a review feed costs nothing.
final class SessionMemo<Value> {
    private struct Entry { let value: Value; let at: Date }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 1.5) { self.ttl = ttl }

    /// The memoized value for `key`, computing it when absent or stale.
    func value(for key: String, compute: () -> Value) -> Value {
        lock.lock()
        if let entry = entries[key], Date().timeIntervalSince(entry.at) < ttl {
            lock.unlock()
            return entry.value
        }
        lock.unlock()
        let fresh = compute()
        lock.lock()
        entries[key] = Entry(value: fresh, at: Date())
        lock.unlock()
        return fresh
    }
}
