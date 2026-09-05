//
//  URL+FileMetadata.swift
//  AgentSession
//
//  The file's content-modification date, or nil when unreadable.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

extension URL {
    /// The file's content-modification date, or nil when unreadable.
    var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// True when the URL names an existing directory.
    var isExistingDirectory: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
