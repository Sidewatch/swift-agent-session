import Foundation

/// Directory questions every adapter asks.
enum Files {
    /// The most recently modified file in `directory` whose extension is in `extensions`
    /// ("the current session"), or nil when there is none or the directory is unreadable.
    static func newest(in directory: URL, extensions: Set<String>) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { extensions.contains($0.pathExtension) }
            .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
    }
}
