//
//  TranscriptCache.swift
//  SwiftAgentSession
//
//  The incremental transcript cache behind ClaudeCodeAdapter's readers: each
//  poll costs O(appended bytes) instead of a full-file read + re-parse.
//
//  Created by David Sherlock on 7/16/26.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The incremental transcript cache behind ``ClaudeCodeAdapter``'s readers.
///
/// One entry per polled project root (keyed by `root.path`) mirrors that root's
/// *current* transcript. Each entry stores the file identity it last observed
/// (path + inode + size + mtime), the byte offset of the first line not yet
/// folded into the durable ``TranscriptState``, and a memoized ``Snapshot`` of
/// all three readers' results.
///
/// Poll algorithm (``results(for:file:)``):
/// 1. `stat` the transcript. Identical path/inode/size/mtime → return the
///    memoized snapshot: **zero file reads**.
/// 2. Same file, size grew (the JSONL append case) → read only `[offset, size)`
///    via POSIX `pread`, split on `\n`, fold the complete lines into the durable
///    state, and advance the offset. An unterminated trailing line is *not*
///    consumed: it is parsed tentatively into a copy of the state for this
///    snapshot only (matching what a full re-parse would report right now) and
///    is re-read on a later poll once completed — the stored offset never moves
///    past an incomplete line.
/// 3. Anything else — path changed (session rotation), inode changed (atomic
///    rewrite), size shrank (truncation), or a same-size mtime change (in-place
///    rewrite) — drops the entry and re-parses the whole file once.
///
/// Thread safety: every access runs under one `NSLock`; readers arrive from
/// multiple background queues, and the first caller after an append performs
/// the single shared parse while subsequent callers serve the memoized snapshot.
///
/// Lifetime: the cache is owned *by reference* by a ``ClaudeCodeAdapter`` value,
/// so copies of one adapter share it and it lives exactly as long as the adapter
/// (and its copies). Entries for roots whose transcript disappears are dropped.
/// Per-entry memory is bounded: the events buffer is capped at 300, and the
/// usage-dedupe / edited-files sets grow only with the session's message count.
///
/// - Note: Lines are parsed as raw bytes. A line that is not valid UTF-8/JSON is
///   skipped individually (the pre-cache code rejected the *whole* file when it
///   was not valid UTF-8 — JSONL is UTF-8 by spec, so this never mattered).
final class TranscriptCache: @unchecked Sendable {

    /// The results one poll serves — all three readers' values, materialized
    /// once per parse so usage/events/summary always come from the same bytes.
    struct Snapshot {
        /// What ``ClaudeCodeAdapter/usage(for:)`` returns.
        let usage: AgentUsage?
        /// What ``ClaudeCodeAdapter/events(for:)`` returns.
        let events: [TimelineEvent]
        /// What ``ClaudeCodeAdapter/summary(for:)`` returns.
        let summary: AgentSummary?
        /// The no-transcript / unreadable-transcript result.
        static let empty = Snapshot(usage: nil, events: [], summary: nil)
    }

    /// Cached incremental state for one project root's current transcript.
    private struct Entry {
        /// The transcript path this entry mirrors (rotation detection).
        var filePath: String
        /// The transcript's inode (atomic rewrites replace the file → new inode).
        var inode: UInt64
        /// The modification date observed at the last poll.
        var mtime: Date?
        /// The content length observed at the last poll (consumed + pending tail).
        var size: UInt64
        /// The first byte not yet folded into `durable`. Always line-aligned:
        /// it never points past an unterminated trailing line.
        var offset: UInt64
        /// Parse state accumulated over all complete lines up to `offset`.
        var durable: TranscriptState
        /// The memoized results (durable state + tentative trailing line).
        var snapshot: Snapshot
    }

    /// Guards all mutable state below. `NSLock` (non-reentrant) is sufficient:
    /// there is a single locked entry point and no nested locking.
    private let lock = NSLock()

    /// Live entries, keyed by `root.path`.
    private var entries: [String: Entry] = [:]

    /// Test seam: how many transcript *content* reads have been performed
    /// (`stat`-only polls do not count). Guarded by `lock`.
    private var reads = 0

    /// Test seam: total transcript bytes read. With incremental polling this
    /// grows by roughly the appended bytes per poll, not the file size. Guarded
    /// by `lock`.
    private var bytes = 0

    /// Thread-safe accessor for the read-count test seam.
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }

    /// Thread-safe accessor for the bytes-read test seam.
    var bytesRead: Int { lock.lock(); defer { lock.unlock() }; return bytes }

    /// Serves the current results for `root`'s transcript `file`, updating the
    /// cache incrementally as described in the type documentation.
    ///
    /// - Parameters:
    ///   - root: The project root being polled (the cache key).
    ///   - file: The resolved current transcript, or `nil` when there is none.
    /// - Returns: The usage/events/summary snapshot, equal to what a full
    ///   re-parse of the file's current contents would produce.
    func results(for root: URL, file: URL?) -> Snapshot {
        lock.lock(); defer { lock.unlock() }

        let key = root.path
        guard let file else {
            entries[key] = nil
            return .empty
        }
        let path = file.path
        guard let att = try? FileManager.default.attributesOfItem(atPath: path) else {
            entries[key] = nil
            return .empty
        }
        let size = (att[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = att[.modificationDate] as? Date
        let inode = (att[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0

        // Fast path: nothing observable changed → serve the memoized snapshot
        // with zero file reads. This is the steady-state poll.
        if let e = entries[key], e.filePath == path, e.inode == inode,
           e.size == size, e.mtime == mtime {
            return e.snapshot
        }

        // Reuse the durable state only for a pure append to the very same file;
        // anything else (rotation, atomic rewrite, shrink, same-size mtime
        // change) starts over and re-parses the whole file once.
        var entry: Entry
        if let e = entries[key], e.filePath == path, e.inode == inode, size > e.size {
            entry = e
        } else {
            entry = Entry(filePath: path, inode: inode, mtime: mtime, size: 0, offset: 0,
                          durable: TranscriptState(), snapshot: .empty)
        }

        // Read exactly [offset, size): the appended bytes, plus the prefix of an
        // unterminated line carried over from the previous poll (offset stays at
        // its start until it completes). Bytes appended after our stat wait for
        // the next poll, keeping this pass internally consistent.
        var appended = Data()
        if size > entry.offset {
            guard let data = read(path: path, from: entry.offset, count: Int(size - entry.offset)) else {
                entries[key] = nil
                return .empty
            }
            appended = data
        }

        // Fold every complete (newline-terminated) line into the durable state.
        let completeEnd = appended.lastIndex(of: 0x0A).map { appended.index(after: $0) } ?? appended.startIndex
        for line in appended[appended.startIndex..<completeEnd].split(separator: 0x0A) where !line.isEmpty {
            entry.durable.ingest(lineData: Data(line))   // rebase the slice's indices
        }
        let tail = appended[completeEnd...]

        entry.offset += UInt64(appended.distance(from: appended.startIndex, to: completeEnd))
        entry.size = entry.offset + UInt64(tail.count)
        entry.mtime = mtime
        entry.inode = inode

        // Materialize the snapshot from the durable state plus a tentative parse
        // of the unterminated tail (a full re-parse would see that line too).
        var served = entry.durable
        if !tail.isEmpty { served.ingest(lineData: Data(tail)) }
        entry.snapshot = Snapshot(usage: served.usageResult,
                                  events: served.eventsResult,
                                  summary: served.summaryResult)
        entries[key] = entry
        return entry.snapshot
    }

    // MARK: - Raw file access

    /// Reads up to `count` bytes starting at `offset` using POSIX `pread`
    /// (positioned reads, no availability constraints on any Apple platform).
    ///
    /// Returns fewer bytes than requested only when the file shrank between the
    /// caller's `stat` and this read (the next poll's identity check recovers),
    /// or `nil` when the file cannot be opened/read at all. Increments the
    /// read/bytes test-seam counters; a zero-length request performs no read.
    private func read(path: String, from offset: UInt64, count: Int) -> Data? {
        guard count > 0 else { return Data() }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        reads += 1

        var data = Data(count: count)
        var filled = 0
        let ok = data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
            guard let base = buf.baseAddress else { return false }
            while filled < count {
                let n = pread(fd, base + filled, count - filled, off_t(offset) + off_t(filled))
                if n == 0 { break }                       // EOF: file shrank since stat
                if n < 0 {
                    if errno == EINTR { continue }        // interrupted — retry
                    return false
                }
                filled += n
            }
            return true
        }
        guard ok else { return nil }
        bytes += filled
        if filled < count { data.removeSubrange(filled..<count) }
        return data
    }
}
