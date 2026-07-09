# Swift Agent Session

A tiny, dependency-free reader for terminal AI coding-agent session transcripts. It maps an agent's on-disk session onto one agent-agnostic model — an activity timeline, token/cost telemetry, and an edited-files/to-dos roll-up — so review surfaces stay identical across agents. Read-only: it never talks to a model, keeps no account, and sends no telemetry.

## Features

- 🧭 **Agent-agnostic model** — `TimelineEvent`, `AgentUsage`, `AgentSummary`
- 🔌 **Adapter protocol** — implement `AgentAdapter` once per agent
- 🤖 **Claude Code adapter** — parses `~/.claude/projects/…/*.jsonl` transcripts
- 🕘 **Activity timeline** — prompts, assistant prose, tool calls, and file edits
- 💰 **Telemetry** — context fill %, output tokens, and estimated USD cost
- ✅ **Plan vs actual** — the files edited and the current to-do list
- 🔎 **Auto-detection** — `Agents.active(for:)` picks the agent that owns a project
- 🪶 **Zero dependencies** — Foundation only
- 🍎 **Cross-platform** — iOS, macOS, tvOS, watchOS, visionOS

## Requirements

- iOS 13.0+ / macOS 10.15+ / tvOS 13.0+ / watchOS 6.0+ / visionOS 1.0+
- Swift 5.9+

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/arraypress/swift-agent-session.git", from: "1.0.0")
]
```

## Usage

```swift
import AgentSession

let root = URL(fileURLWithPath: "/path/to/project")

if let agent = Agents.active(for: root) {
    for event in agent.events(for: root) {
        print("\(event.timestamp)  \(event.title): \(event.detail)")
    }

    if let usage = agent.usage(for: root) {
        print("context \(usage.contextPercent)%  ·  $\(usage.costUSD)  ·  \(usage.outputTokens) out")
    }

    if let summary = agent.summary(for: root) {
        print("edited \(summary.editedFiles.count) files")
        for todo in summary.todos { print("[\(todo.status)] \(todo.text)") }
    }
}
```

## License

MIT
