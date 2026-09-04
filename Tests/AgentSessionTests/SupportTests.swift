import XCTest
@testable import AgentSession

/// The helpers the adapters share. Each adapter used to carry its own copy (or its own
/// near-copy) of these — a Gemini `modified` identical to an OpenCode `modified`, three ways
/// to pick the newest file, two HH:mm formatters.
final class SupportTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testLenientUTF8DropsOnlyATruncatedTrailingCharacter() {
        let euro = Array("€".utf8)   // 3 bytes
        XCTAssertEqual(Data(Array("x".utf8) + euro.prefix(2)).lenientUTF8String, "x", "2 of 3 bytes of € dropped")
        XCTAssertEqual(Data(Array("x".utf8) + euro.prefix(1)).lenientUTF8String, "x", "1 of 3 bytes dropped")
        XCTAssertEqual(Data("clean €".utf8).lenientUTF8String, "clean €", "valid input untouched")
        XCTAssertNil(Data([0xFF, 0xFE, 0xFD, 0xFC, 0xFB]).lenientUTF8String, "garbage is still nil")
    }

    func testNewestFilePicksByModificationDateWithinTheExtensions() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let old = d.appendingPathComponent("old.jsonl"), new = d.appendingPathComponent("new.jsonl"), other = d.appendingPathComponent("newer.txt")
        try "a".write(to: old, atomically: true, encoding: .utf8)
        try "b".write(to: new, atomically: true, encoding: .utf8)
        try "c".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: +60)], ofItemAtPath: other.path)
        XCTAssertEqual(Files.newest(in: d, extensions: ["jsonl"])?.lastPathComponent, "new.jsonl", "the .txt is newer but not a candidate")
        XCTAssertNil(Files.newest(in: d.appendingPathComponent("missing"), extensions: ["jsonl"]))
        XCTAssertEqual(old.modificationDate.map { Int($0.timeIntervalSinceNow) } ?? 0, -60, accuracy: 2)
        XCTAssertTrue(d.isExistingDirectory); XCTAssertFalse(new.isExistingDirectory)
    }

    func testJSONLinesSkipsUnparseableLinesAndObjectReadsAFile() throws {
        let lines = JSONFile.lines(in: "{\"a\":1}\nnot json\n{\"b\":2}\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[1]["b"] as? Int, 2)
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("s.json")
        try "{\"id\":\"s1\"}".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(JSONFile.object(at: f)?["id"] as? String, "s1")
        XCTAssertNil(JSONFile.object(at: d.appendingPathComponent("nope.json")))
        try "[1,2]".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertNil(JSONFile.object(at: f), "an array is not an object")
    }

    func testFileHeadReadsOnlyTheHeadAndDecodesLeniently() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("big.jsonl")
        try (String(repeating: "x", count: 10) + "€" + String(repeating: "y", count: 100)).write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(FileHead.text(of: f, bytes: 12), "xxxxxxxxxx", "the cut lands inside €; the head survives without it")
        XCTAssertNil(FileHead.text(of: d.appendingPathComponent("missing")))
    }

    func testClockFormatIs24HourRegardlessOfLocaleAndEpochMillisecondsAreMilliseconds() {
        let date = Date(epochMilliseconds: 1_700_000_000_000)   // 2023-11-14T22:13:20Z
        XCTAssertEqual(date.timeIntervalSince1970, 1_700_000_000, accuracy: 0.001)
        let text = ClockFormat.hhmm(date)
        XCTAssertNotNil(text.range(of: #"^\d\d:\d\d$"#, options: .regularExpression), text)
        XCTAssertFalse(text.contains("PM") || text.contains("AM"))
    }
}
