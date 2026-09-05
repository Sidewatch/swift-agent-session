//
//  Data+Lines.swift
//  AgentSession
//
//  The newline-terminated lines (without their terminators, empties dropped) and the
//  unterminated tail that follows the last newline.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

extension Data {
    /// The newline-terminated lines (without their terminators, empties dropped) and the
    /// unterminated tail that follows the last newline.
    var completeLinesAndTail: (lines: [Data], tail: Data) {
        let end = lastIndex(of: 0x0A).map { index(after: $0) } ?? startIndex
        let lines = self[startIndex..<end].split(separator: 0x0A).filter { !$0.isEmpty }.map { Data($0) }
        return (lines, Data(self[end...]))
    }
}
