import Foundation

/// Reading JSON the way agent transcripts store it: whole-file objects and JSON Lines.
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

    /// One object per parseable line of JSON Lines text; unparseable lines are skipped.
    static func lines(in text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return object(from: data)
        }
    }
}
