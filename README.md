# Swift Agent Session

A tiny, dependency-free reader for terminal AI coding-agent session transcripts. It maps an agent's on-disk session onto one agent-agnostic model — an activity timeline, token/cost telemetry, and an edited-files/to-dos roll-up — so review surfaces stay identical across agents. Read-only: it never talks to a model, keeps no account, and sends no telemetry.

## Features

- 🧭 **Agent-agnostic model** — `TimelineEvent`, `AgentUsage`, `AgentSummary`
- 🔌 **Adapter protocol** — implement `AgentAdapter` once per agent
- 🤖 **Claude Code adapter** — `ClaudeCodeAdapter` parses `~/.claude/projects/…/*.jsonl` transcripts
- 🕘 **Activity timeline** — prompts, assistant prose, tool calls, and file edits, with local-clock `HH:MM` timestamps
- 💰 **Telemetry** — context fill % (`AgentUsage.contextPercent`), output tokens, and estimated USD cost, deduplicated per API response
- ✅ **Plan vs actual** — the files edited (Edit / Write / MultiEdit / NotebookEdit) and the current to-do list
- 🔎 **Auto-detection** — `Agents.active(for:)` picks the agent that owns a project
- 🧪 **Fully tested** — synthetic-transcript tests including malformed, truncated, and garbage input
- 🪶 **Zero dependencies** — Foundation only
- 🍎 **Cross-platform** — iOS, macOS, tvOS, watchOS, visionOS

## Requirements

- iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 6.0+ / visionOS 1.0+
- Swift 5.9+

## Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/Sidewatch/swift-agent-session.git", from: "1.0.0")
]
```

## Usage

```swift
import AgentSession

let root = URL(fileURLWithPath: "/path/to/project")

// Which agent has a session here? First match in Agents.all wins.
if let agent = Agents.active(for: root) {
    print(agent.name)   // e.g. Claude Code

    // The activity timeline, oldest first (most recent 300 events).
    for event in agent.events(for: root) {
        print("\(event.timestamp)  \(event.title): \(event.detail)")
        // event.kind: .userPrompt / .assistantText / .toolUse / .fileEdit
        // event.filePath: navigable absolute path, when the event touched one
    }

    // Token/cost telemetry — nil when the transcript has no usage records.
    if let usage = agent.usage(for: root) {
        print("context \(usage.contextPercent)%  ·  $\(usage.costUSD)  ·  \(usage.outputTokens) out")
    }

    // The edited-files / to-dos roll-up for a Plan-vs-Actual view.
    if let summary = agent.summary(for: root) {
        print("edited \(summary.editedFiles.count) files")
        for todo in summary.todos { print("[\(todo.status)] \(todo.text)") }
    }
}
```

### Adding an agent

```swift
// Implement the protocol against the agent's native transcript format…
struct MyAgentAdapter: AgentAdapter {
    var name: String { "My Agent" }
    func hasSession(for root: URL) -> Bool { /* … */ }
    func events(for root: URL) -> [TimelineEvent] { /* … */ }
    func usage(for root: URL) -> AgentUsage? { /* … */ }
    func summary(for root: URL) -> AgentSummary? { /* … */ }
}
// …and append it to Agents.all — every consumer stays agent-agnostic.
```

## Notes

- All calls are **synchronous** file reads over the newest transcript. When sessions may be large, dispatch them off the main queue.
- Only the **latest session** (most recently modified `.jsonl`) per project is read.
- Costs are **estimates** from approximate per-model list prices (Opus / Haiku / Sonnet-default tiers); repeated JSONL lines for the same API response are counted once.
- The parser is defensive: malformed, truncated, or garbage lines are skipped, never fatal.

## License

MIT
