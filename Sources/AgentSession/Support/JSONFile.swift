//
//  JSONFile.swift
//  AgentSession
//
//  Reading JSON the way agent transcripts store it: whole-file objects, and one line's bytes.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// Reading JSON the way agent transcripts store it: whole-file objects, and one line's bytes
/// (`TranscriptCache` splits the file itself).
enum JSONFile {
    /// The top-level object of a JSON file, or nil when unreadable or not an object.
    static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return object(from: data)
    }

    /// The top-level object in `data`, or nil.
    static func object(from data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
