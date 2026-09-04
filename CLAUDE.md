# Swift Agent Session

A tiny, dependency-free reader for terminal AI coding-agent session transcripts. It maps an agent's on-disk session onto one agent-agnostic model — an activity timeline, token/cost telemetry, and an edited-files/to-dos roll-up — so review surfaces stay identical across agents. Read-only: it never talks to a model, keeps no account, and sends no telemetry.

- Module `AgentSession` in `Sources/AgentSession`; tests in `Tests`; `swift test` is the whole check.
- Swift 6 language mode, tools 6.0, macOS 14+, no dependencies unless the README says so.
- Part of the Sidewatch package family; every package follows the same layout and PR rules.

## Module map

- `Adapters/` — the engine: adapters: Agents, ClaudeCodeAdapter, CodexAdapter, GeminiAdapter, OpenCodeAdapter
- `Models/` — value types — the shape of a thing, nothing else: AgentSummary, AgentUsage, ClaudeCredentials, ClaudeQuota, TimelineEvent, TurnBoundary, UsageReport
- `Protocols/` — protocols the module exposes: AgentAdapter
- `Transcripts/` — the engine: transcripts: SessionMemo, TranscriptCache, TranscriptState
- `Usage/` — the engine: usage: ModelPricing, UsageAggregator

## Rules

@CONTRIBUTING.md
