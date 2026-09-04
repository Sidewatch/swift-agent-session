import Foundation

/// What a poll needs to know about a file without reading it: size, mtime, inode.
struct FileStat: Equatable {
    let size: UInt64
    let mtime: Date?
    let inode: UInt64

    /// Nil when the file cannot be stat'ed.
    init?(path: String) {
        guard let att = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        size = (att[.size] as? NSNumber)?.uint64Value ?? 0
        mtime = att[.modificationDate] as? Date
        inode = (att[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    }
}
