import XCTest
@testable import AgentSession

final class ClaudeCredentialsTests: XCTestCase {

    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testNestedClaudeCodeShape() {
        let json = #"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"r","expiresAt":123}}"#
        XCTAssertEqual(ClaudeCredentials.accessToken(fromKeychainData: data(json)), "sk-ant-oat01-abc")
    }

    func testFlatShape() {
        XCTAssertEqual(ClaudeCredentials.accessToken(fromKeychainData: data(#"{"accessToken":"sk-ant-oat01-xyz"}"#)),
                       "sk-ant-oat01-xyz")
    }

    func testBareToken() {
        XCTAssertEqual(ClaudeCredentials.accessToken(fromKeychainData: data("  sk-ant-oat01-bare\n  ")),
                       "sk-ant-oat01-bare")
    }

    func testGarbageAndEmptyReturnNil() {
        XCTAssertNil(ClaudeCredentials.accessToken(fromKeychainData: data("not a token")))
        XCTAssertNil(ClaudeCredentials.accessToken(fromKeychainData: data("{}")))
        XCTAssertNil(ClaudeCredentials.accessToken(fromKeychainData: data(#"{"claudeAiOauth":{"accessToken":""}}"#)))
        XCTAssertNil(ClaudeCredentials.accessToken(fromKeychainData: Data()))
    }
}
