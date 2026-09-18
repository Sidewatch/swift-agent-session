//
//  ClaudeKeychainTests.swift
//  AgentSessionTests
//
//  What the `security` tool prints is the blob plus a newline; nothing, or noise, is no token.
//
//  Created by David Sherlock on 9/18/26.
//

import XCTest
@testable import AgentSession

/// Tests for `ClaudeKeychain.token(fromToolOutput:)`: the tool's output shape, and the empty and
/// refused cases. The live reads are not tested here — they touch the user's Keychain.
final class ClaudeKeychainTests: XCTestCase {
    func testTheToolsOutputIsTheBlobPlusANewline() {
        let printed = Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-tool","refreshToken":"r"}}"#.utf8) + Data("\n".utf8)
        XCTAssertEqual(ClaudeKeychain.token(fromToolOutput: printed), "sk-ant-oat01-tool")
        XCTAssertEqual(ClaudeKeychain.token(fromToolOutput: Data("sk-ant-oat01-bare\n".utf8)), "sk-ant-oat01-bare", "a bare token, trimmed")
    }

    func testNothingOrNoiseIsNoToken() {
        XCTAssertNil(ClaudeKeychain.token(fromToolOutput: Data()))
        XCTAssertNil(ClaudeKeychain.token(fromToolOutput: Data("\n".utf8)))
        XCTAssertNil(ClaudeKeychain.token(fromToolOutput: Data("security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain.\n".utf8)))
    }

    func testAMissingServiceReadsAsNilWithoutHanging() {
        // No item under this service on any Mac; the tool exits 44 and the read is nil, fast.
        let started = Date()
        XCTAssertNil(ClaudeKeychain.accessTokenViaSecurityTool(service: "Sidewatch-no-such-item-\(UUID().uuidString)"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
