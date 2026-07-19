import Foundation

/// Extracts the Claude Code OAuth access token from the raw bytes of its macOS
/// Keychain item (`Claude Code-credentials`). Pure + lenient so it's testable off a
/// device: the actual `SecItemCopyMatching` read lives app-side.
///
/// Claude Code stores a JSON blob — `{"claudeAiOauth":{"accessToken":"sk-ant-oat…",
/// …}}` — but some setups store the token flat or bare, so all three shapes are
/// accepted. Reading the live Keychain token (rather than a pasted copy) means the
/// token Claude Code silently refreshes is always the one used.
public enum ClaudeCredentials {

    /// Pulls the `sk-ant-…` access token out of the Keychain item data, or nil if the
    /// bytes carry no recognizable token.
    public static func accessToken(fromKeychainData data: Data) -> String? {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // Nested (Claude Code's shape) …
            if let oauth = obj["claudeAiOauth"] as? [String: Any],
               let token = oauth["accessToken"] as? String, !token.isEmpty {
                return token
            }
            // … or flat.
            if let token = obj["accessToken"] as? String, !token.isEmpty { return token }
            return nil
        }
        // Bare token stored directly.
        if let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           s.hasPrefix("sk-ant") {
            return s
        }
        return nil
    }
}
