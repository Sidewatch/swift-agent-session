//
//  ClaudeSessionIndex.swift
//  AgentSession
//
//  Resolves a Claude Code **session id** to the directory that session is running in.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// Resolves a Claude Code **session id** to the directory that session is running in.
///
/// A `Stop` or `Notification` hook carries only a `session_id`. The answer is on disk: Claude
/// Code writes each session's transcript to `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl`,
/// so the session id IS the filename and its parent directory encodes the working directory.
///
/// Matching ENCODES the candidate directory rather than decoding the folder name: the encoding
/// replaces every character outside ASCII `[A-Za-z0-9]` with `-`, so it is lossy and cannot be
/// reversed. Two different paths can still encode alike, which is why a host should treat this
/// as the FALLBACK when a hook payload carries no `cwd` of its own.
public final class ClaudeSessionIndex: @unchecked Sendable {
    /// `~/.claude/projects`.
    public static let defaultProjectsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)
    /// The index over the real projects folder.
    public static let shared = ClaudeSessionIndex(projectsRoot: defaultProjectsRoot)

    public let projectsRoot: URL
    /// session id → encoded project directory. Sessions do not move between directories, so a
    /// hit is cached for the life of the process; the scan is a directory walk and hooks arrive
    /// in bursts.
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    public init(projectsRoot: URL) { self.projectsRoot = projectsRoot }

    /// The encoded project directory for `sessionID`, or nil when no transcript is found — a
    /// normal outcome: a `Stop` hook can beat the transcript to disk on a brand-new session.
    public func projectDirectory(forSession sessionID: String) -> String? {
        lock.lock()
        if let hit = cache[sessionID] { lock.unlock(); return hit }
        lock.unlock()
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(atPath: projectsRoot.path) else { return nil }
        let filename = "\(sessionID).jsonl"
        for dir in dirs where fm.fileExists(atPath: projectsRoot.appendingPathComponent(dir).appendingPathComponent(filename).path) {
            lock.lock(); cache[sessionID] = dir; lock.unlock()
            return dir
        }
        return nil
    }

    /// Whether `url` is the directory that `sessionID` is running in.
    public func directory(_ url: URL, matchesSession sessionID: String) -> Bool {
        guard let dir = projectDirectory(forSession: sessionID) else { return false }
        return Self.candidateEncodings(of: url).contains(dir)
    }

    /// Clears the cache — for tests.
    public func resetCache() { lock.lock(); cache.removeAll(); lock.unlock() }

    // MARK: - The encoding

    /// A directory encoded the way Claude Code names its project folders.
    ///
    /// MEASURED, not assumed: running claude in a directory named `Tëst_Prøjéct 2.0` produced
    /// `T-st-Pr-j-ct-2-0` — every UTF-16 unit outside ASCII `[A-Za-z0-9]` becomes `-`.
    public static func encode(_ url: URL) -> String { fold(url.standardizedFileURL.path) }

    /// Every encoding the session's transcript folder could plausibly carry for `url`:
    /// - Unicode: an `é` can live on disk precomposed (one unit → one `-`) or decomposed
    ///   (`e` + combining accent → `e-`), and Foundation re-normalizes URLs behind your back,
    ///   so fold as-is, NFC and NFD.
    /// - `/private`: `standardizedFileURL` strips `/private` from `/tmp`, `/var`, `/etc`, but the
    ///   kernel-reported cwd Claude encodes carries it — so both spellings are candidates.
    public static func candidateEncodings(of url: URL) -> Set<String> {
        let path = url.standardizedFileURL.path
        var spellings = [path]
        for base in ["/tmp", "/var", "/etc"] where path == base || path.hasPrefix(base + "/") {
            spellings.append("/private" + path)
        }
        var out = Set<String>()
        for s in spellings {
            out.insert(fold(s))
            out.insert(fold(s.precomposedStringWithCanonicalMapping))
            out.insert(fold(s.decomposedStringWithCanonicalMapping))
        }
        return out
    }

    /// Per UTF-16 CODE UNIT, mirroring Claude Code's own JS replacement: a non-BMP character
    /// (an emoji in a folder name) is two units and folds to TWO dashes.
    private static func fold(_ path: String) -> String {
        var out = ""
        for unit in path.utf16 {
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: out.append(Character(UnicodeScalar(unit)!))
            default: out.append("-")
            }
        }
        return out
    }
}
