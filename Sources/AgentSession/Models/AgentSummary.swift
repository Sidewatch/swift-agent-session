//
//  AgentSummary.swift
//  SwiftAgentSession
//
//  A roll-up of what the agent has done this session — the files it edited and
//  its current to-do list — for the Plan-vs-Actual view.
//
//  Created by David Sherlock on 7/9/26.
//

import Foundation

/// A session roll-up: the files an agent edited and its current to-do list.
public struct AgentSummary {

    /// Absolute paths of every file the agent wrote to this session.
    public let editedFiles: Set<String>

    /// The agent's current to-do items as `(text, status)` pairs.
    public let todos: [(text: String, status: String)]

    public init(editedFiles: Set<String>, todos: [(text: String, status: String)]) {
        self.editedFiles = editedFiles
        self.todos = todos
    }
}
