//
//  ClaudeQuotaCache.swift
//  AgentSession
//
//  A throttled, last-good-value cache in front of a quota fetch.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// A throttled, last-good-value cache in front of a quota fetch. Never re-fetches more often than
/// `minRefreshInterval` — polling harder is exactly what makes the endpoint 429, so the cache is
/// a correctness feature, not an optimisation. Delivers on the main queue.
public final class ClaudeQuotaCache: @unchecked Sendable {
    public let minRefreshInterval: TimeInterval
    private let fetch: @Sendable (String) -> ClaudeQuota?
    private let lock = NSLock()
    private var cached: ClaudeQuota?
    private var lastFetch: Date?
    private var inFlight = false

    /// `fetch` turns a session token into a quota (nil on failure); default is the live endpoint.
    public init(minRefreshInterval: TimeInterval = 180,
                fetch: @escaping @Sendable (String) -> ClaudeQuota? = { ClaudeUsageEndpoint.fetchQuota(sessionKey: $0) }) {
        self.minRefreshInterval = minRefreshInterval
        self.fetch = fetch
    }

    /// The last value, without fetching.
    public var lastValue: ClaudeQuota? { lock.lock(); defer { lock.unlock() }; return cached }

    /// Delivers the quota on the main queue: the cached value immediately if it is fresh or a
    /// fetch is in flight, otherwise fetches off-main first (resolving `token` there, since a
    /// Keychain read can prompt). Nil when `token` yields nothing. A failed refresh keeps the last
    /// good value. `force` ignores freshness (still gated by an in-flight fetch).
    public func quota(force: Bool = false, token: @escaping @Sendable () -> String?,
                      completion: @escaping @Sendable (ClaudeQuota?) -> Void) {
        lock.lock()
        let fresh = !force && (lastFetch.map { Date().timeIntervalSince($0) < minRefreshInterval } ?? false)
        if fresh || inFlight {
            let value = cached; lock.unlock()
            DispatchQueue.main.async { completion(value) }
            return
        }
        inFlight = true
        lock.unlock()
        let fetch = self.fetch
        DispatchQueue.global(qos: .utility).async { [self] in
            let fetched = token().flatMap(fetch)
            lock.lock()
            if fetched != nil { cached = fetched }
            lastFetch = Date(); inFlight = false
            let value = cached
            lock.unlock()
            DispatchQueue.main.async { completion(value) }
        }
    }
}
