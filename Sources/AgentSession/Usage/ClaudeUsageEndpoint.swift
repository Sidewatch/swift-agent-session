import Foundation

/// Anthropic's **internal, undocumented** OAuth usage endpoint: the plan's remaining 5-hour /
/// weekly quota, for a session token.
///
/// EXPERIMENTAL + UNSUPPORTED: `/api/oauth/usage` is not a public API. It may return 401/403/429,
/// change shape, or vanish — every path here fails soft. The endpoint rate-limits aggressively
/// and keys its generous bucket on a `claude-code/<version>` User-Agent (a plain UA gets
/// persistent 429s), so the probe presents that UA; polling faster than a few minutes is what
/// makes it 429 — see ``ClaudeQuotaCache``.
public enum ClaudeUsageEndpoint {
    public static let url = "https://api.anthropic.com/api/oauth/usage"
    /// Required for the non-throttled bucket. Bump if the endpoint starts rejecting an old client.
    public static let userAgent = "claude-code/2.1.0"

    /// Synchronously fetches and parses the quota, or nil on any non-200 / unparseable
    /// response. Off-main only.
    public static func fetchQuota(sessionKey: String) -> ClaudeQuota? {
        guard let (status, body) = fetchRaw(sessionKey: sessionKey), status == 200 else { return nil }
        return ClaudeQuota.parse(body)
    }

    /// Synchronously GETs the endpoint: HTTP status + raw body, or nil on a transport failure.
    /// Synchronous by design — it backs diagnostics and the off-main fetch. Never call on main.
    public static func fetchRaw(sessionKey: String, timeout: TimeInterval = 12) -> (status: Int, body: String)? {
        guard let url = URL(string: url) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "GET"
        req.setValue("Bearer \(sessionKey)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        nonisolated(unsafe) var result: (Int, String)?   // written once by the task, read after the semaphore
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { result = (-1, "transport error: \(err.localizedDescription)"); return }
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            result = (status, data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result
    }
}
