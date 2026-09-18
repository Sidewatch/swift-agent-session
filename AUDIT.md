# Audit log

Last full audit: **17 Sep 2026** — every source file covered by the MECHANICAL checks below (build warnings, tests,
dead-code and risk-pattern scans, docs drift); line-by-line logic review was targeted at the areas changed since
5 Sep 2026, not the whole tree. Nothing needs re-scanning unless it changed after that date. Add a dated line under *History* when you audit again, and keep the
*Known non-issues* list current so the next pass skips them.

## What a full audit checks

1. `swift build` warnings (none allowed except those listed under known non-issues) and `swift test` green.
2. Dead code: every `func`/type/property declared once and referenced nowhere in the app or the family
   (`grep -w` across `*.swift` AND non-Swift files — selectors and MCP names live in strings). Protocol
   requirements, `override`s, `@objc` actions and public API are NOT dead because Sidewatch does not call them.
3. Risky patterns: `Timer` without `invalidate`, `addObserver(forName:)` without `removeObserver`, `as!`, `try!`
   outside literal regexes, `fatalError` outside `init?(coder:)`, `print(` outside harnesses, TODO/FIXME left behind.
4. Docs drift: every name in CLAUDE.md's module map exists; AGENTS.md mirrors CLAUDE.md; README Usage matches the API.

## Result on 17 Sep 2026

- Build: clean. Tests: green.
- Fixed: `ClockFormat.hhmm`: dropped a `nonisolated(unsafe)` the compiler reported as unnecessary (DateFormatter is Sendable now).
- Fixed: CLAUDE.md / AGENTS.md module map listed CodexAdapter, GeminiAdapter, OpenCodeAdapter — only `ClaudeCodeAdapter` (+ `Agents`) exists.

## Logic review — 18 Sep 2026 (every source and test file, line by line)

Fixed, each pinned by a test that fails against the old code:

- **The usage heatmap and streaks bucketed by UTC day.** `UsageRecord.day` was the timestamp's
  first ten characters — its UTC date — so for anyone west of UTC every evening's work landed on
  tomorrow's cell and `currentStreak` read 0 until the next day (`streaks` compares against a LOCAL
  "today"). The day and the peak hour now come from the parsed instant in the local calendar
  (`ISOTimestamp`, shared with the timeline's `HH:mm`); the raw-string reads remain as the
  fallback for a timestamp the parser rejects.
- **A CRLF edit had no usable anchor.** `editAnchor` split `new_string` on the Character `"\n"`,
  and `"\r\n"` is ONE Character in Swift, so a Windows-authored file's edit kept its whole
  inserted text as the anchor — which no single line contains — and Follow Agent fell back to the
  first hunk. `firstLine` (prompt and prose rows) and `BurnDetector.key`'s label had the same split.
  All three split on `isNewline` now.
- **Helpers left over from the removed adapters** (`SessionMemo`, `FileHead`, `Data.lenientUTF8String`,
  `Date(epochMilliseconds:)`, `JSONFile.lines(in:)`) had no caller outside their own tests since
  11 Sep 2026; removed with their tests. The module map gains the `Support/` line it never had.

Reviewed and sound: `TranscriptCache` (the stat fast path, pure-append detection by inode and size,
the line-aligned offset, the tentative parse of an unterminated tail into a COPY of the state, the
`pread` loop), `TranscriptState` (message-id dedupe across polls, the 300-event cap, `<`-prefixed
user content skipped, read-only tools never file edits), `TurnBoundary` (FNV ids, events before the
first prompt dropped), `BurnDetector` (prose skipped, prompts and edits end a run, bookkeeping
ignored), `ClaudeQuota.parse` and its microsecond dates, `ClaudeQuotaCache`'s throttle (a failed
refresh still stamps `lastFetch`, so failures cannot hammer the endpoint), `ClaudeSessionIndex`'s
per-UTF-16-unit fold and candidate encodings, `Agents.resolve`'s candidate order.

## Known non-issues (do not "fix" these again)

- `ClaudeQuotaCache.lastValue` has no caller in Sidewatch — public API, kept on purpose.
- `ModelPricing` prices a Fable model at the Sonnet rates (no list price recorded here yet); the app
  labels every cost as approximate.
- `TurnBoundary.id` collapses two turns opened by the same text within one clock minute — documented on
  the property; fixing it means a full-precision timestamp on `TimelineEvent`.

## History

- 17 Sep 2026 — full audit (app + all 20 libraries), Claude with David.
- 18 Sep 2026 — logic review (every source and test file, line by line), Claude with David.
