//
//  TranscriptFormat.swift
//  AgentSession
//
//  Accumulated parse state for one Claude Code JSONL transcript.
//
//  Created by David Sherlock on 9/5/26.
//

import Foundation

/// Accumulated parse state for one Claude Code JSONL transcript.
///
/// ``TranscriptCache`` feeds this struct one *complete* transcript line at a
/// time via ``ingest(lineData:)``; the struct keeps the running usage
/// accumulators, the bounded events buffer, and the summary roll-up, and
/// materializes the public model values on demand. Ingesting lines A then B
/// leaves exactly the same state as parsing a file containing A + B from
/// scratch — that equivalence is what lets the cache serve full-fidelity
/// results from only the appended bytes of a growing transcript.
///
/// Value semantics are deliberate: the cache copies the durable state and
/// tentatively ingests an unterminated trailing line into the *copy*, so the
/// served snapshot matches a full re-parse of the file as it stands right now
/// without contaminating the accumulators future polls build on.
/// Which agent's transcript dialect a ``TranscriptState`` is folding.
///
/// The incremental read machinery (stat, append-only offsets, durable state) is identical for
/// every agent; only the per-line shape differs. Carrying the dialect here keeps one cache
/// rather than one per adapter.
enum TranscriptFormat {
    /// Claude Code: `{type, message:{role, content:[…]}}`.
    case claude
    /// Codex CLI: `{timestamp, type, payload:{…}}` with an internally-tagged payload.
    case codex
}
