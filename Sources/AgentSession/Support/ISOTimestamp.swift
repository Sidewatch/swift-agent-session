//
//  ISOTimestamp.swift
//  AgentSession
//
//  The ISO-8601 instant a transcript line carries, parsed once for the timeline and the usage
//  roll-up alike.
//
//  Created by David Sherlock on 9/18/26.
//

import Foundation

/// The ISO-8601 instant a transcript line carries (`2026-07-09T10:07:12.000Z`, or without the
/// fraction), parsed by two formatters built once. Apple documents `ISO8601DateFormatter` as
/// safe for concurrent USE once configured; it is simply not annotated `Sendable`, and both of
/// these are configured here and only ever read.
enum ISOTimestamp {
    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    /// The instant, or nil when `s` is not ISO-8601.
    static func date(_ s: String) -> Date? { fractional.date(from: s) ?? plain.date(from: s) }
}
