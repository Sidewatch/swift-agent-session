//
//  SupportTests.swift
//  AgentSessionTests
//
//  The helpers the adapters share.
//
//  Created by David Sherlock on 9/5/26.
//

import XCTest
@testable import AgentSession

/// The helpers the adapter and the usage roll-up share: the newest-file pick, the JSON object
/// reader, the fixed-locale clock.
final class SupportTests: XCTestCase {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("support-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
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

    func testJSONObjectReadsAFileAndRejectsAnArray() throws {
        let d = try tempDir(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("s.json")
        try "{\"id\":\"s1\"}".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertEqual(JSONFile.object(at: f)?["id"] as? String, "s1")
        XCTAssertNil(JSONFile.object(at: d.appendingPathComponent("nope.json")))
        try "[1,2]".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertNil(JSONFile.object(at: f), "an array is not an object")
    }

    func testClockFormatIs24HourRegardlessOfLocale() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14T22:13:20Z
        let text = ClockFormat.hhmm(date)
        XCTAssertNotNil(text.range(of: #"^\d\d:\d\d$"#, options: .regularExpression), text)
        XCTAssertFalse(text.contains("PM") || text.contains("AM"))
    }
}
