//
//  ClaudeKeychain.swift
//  AgentSession
//
//  Claude Code's OAuth credentials in the login Keychain.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation
import Security

/// Claude Code's OAuth credentials in the login Keychain.
///
/// Claude Code writes the item with Apple's `security` tool, so the item's partition list is
/// `apple-tool:` (checked on a live Mac, 18 Sep 2026): Apple's command-line tools read it
/// silently, and any GUI app reading it through the Security framework is asked for the login
/// password every time — "Always Allow" adds the app's team to the list, and the next token
/// refresh rewrites the item and forgets it. So the first path here IS that tool, spawned for a
/// silent read that is fresh on every call; the framework read remains the fallback for an item
/// written some other way, and a host should take that one at most once per launch.
public enum ClaudeKeychain {
    /// The generic-password service Claude Code stores its credentials under.
    public static let service = "Claude Code-credentials"

    /// The current access token, or nil when the item is absent or access is denied: the
    /// `security` tool first (silent), then the Security framework (may prompt).
    public static func accessToken(service: String = service) -> String? {
        accessTokenViaSecurityTool(service: service) ?? accessTokenViaFramework(service: service)
    }

    /// The token through `/usr/bin/security find-generic-password -w`, which reads an
    /// `apple-tool:` item without a prompt. Nil when the tool finds no item, is refused, or has
    /// not answered within five seconds (it is killed then, so a dialog it might raise for an
    /// item in some other partition cannot hang the caller). Off-main.
    public static func accessTokenViaSecurityTool(service: String = service) -> String? {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        tool.arguments = ["find-generic-password", "-s", service, "-w"]
        let out = Pipe()
        tool.standardOutput = out
        tool.standardError = FileHandle.nullDevice
        do { try tool.run() } catch { return nil }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { if tool.isRunning { tool.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        guard tool.terminationStatus == 0 else { return nil }
        return token(fromToolOutput: data)
    }

    /// The tool prints the secret followed by a newline; the secret is Claude Code's JSON blob
    /// (or, in other setups, a bare token), which ``ClaudeCredentials`` reads.
    static func token(fromToolOutput data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return ClaudeCredentials.accessToken(fromKeychainData: Data(text.utf8))
    }

    /// The Security framework read. For an item outside the app's partition macOS shows an
    /// access prompt ("Always Allow" makes it silent for a signed app until the item is
    /// rewritten); an unsigned build re-prompts on every read. Hosts read at most once per launch.
    public static func accessTokenViaFramework(service: String = service) -> String? {
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
