import Foundation

/// The first bytes of a file as text. A transcript can grow to megabytes and the fact wanted
/// (a recorded `cwd`) sits near the top, so matching a project must not cost a full read.
enum FileHead {
    /// Up to `bytes` from the start of `url`, decoded leniently (a partial trailing character
    /// is dropped, not the whole head). Nil when the file cannot be opened.
    static func text(of url: URL, bytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return handle.readData(ofLength: bytes).lenientUTF8String
    }
}
