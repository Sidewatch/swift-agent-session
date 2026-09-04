import Foundation
import Security

/// Claude Code's OAuth credentials in the login Keychain. The first read shows a macOS access
/// prompt ("Always Allow" makes it silent thereafter, for a signed app); an unsigned build
/// re-prompts on every read, so hosts should read at most once per launch.
public enum ClaudeKeychain {
    /// The generic-password service Claude Code stores its credentials under.
    public static let service = "Claude Code-credentials"

    /// The current access token, or nil when the item is absent or access is denied. The blob is
    /// parsed by ``ClaudeCredentials``.
    public static func accessToken(service: String = service) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return ClaudeCredentials.accessToken(fromKeychainData: data)
    }
}
