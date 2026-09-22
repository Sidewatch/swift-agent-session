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

### Usage prices and plan limits, later on 18 Sep 2026

Two more fixes from comparing the dashboard with what Claude Code itself shows, each pinned by a test that
fails against the old code:

- **`ModelPricing` charged by family name only, and every family had moved.** The table was Opus 4.1 /
  Sonnet 4 / Haiku 3.5 list prices, applied by substring: `claude-opus-5` (the most-used model in the
  local transcripts) was charged $15/$75 where the published price is $5/$25 — three times over —
  while `claude-fable-5-1` fell to the Sonnet default, $3/$15 against $10/$50, and Sonnet 5 and
  Haiku 4.5 were off too. Rates now follow the generation read from the id (both id shapes, the 8-digit
  date ignored), from platform.claude.com/docs/en/about-claude/pricing as read that day; an id with no
  version keeps its family's older rates, which is also what keeps the fixture-based tests honest.
  Mutant: every Opus at the 4.1 rates → `ModelPricingTests` fails, nothing else.
- **`ClaudeQuota.parse` missed the Fable weekly cap and showed a codename bucket instead.** A live
  response (`--dump-quota`, 18 Sep 2026) carries the per-model cap ONLY in a new `limits` array
  (`kind: weekly_scoped`, `scope.model.display_name: "Fable"`, with a `severity`); the top-level
  `seven_day_opus` / `seven_day_sonnet` keys are null and there is no `seven_day_fable` at all. The
  shape-based sweep therefore rendered the 5-hour and weekly bars, an "Extra Usage" percentage and an
  internal feature bucket by its codename — the one bar the user was about to hit absent. The `limits`
  array is now the source of truth when present (keys `session`, `weekly_all`, `weekly_scoped:<Name>`;
  the legacy accessors read them), the older shape still parses when it is absent, `extra_usage` is
  never a limit row, `spend` / `extra_usage` become `Spend` (minor units, currency, exponent → "£12.34
  of £100.00"), and `seven_day_breakdown` becomes `weekShares`. Mutants: ignore `limits` → the
  limits test fails; drop the spend → the two spend tests fail; nothing else either way.
- **The Keychain read prompted on every launch, sometimes twice.** Claude Code writes its
  credential item with the `security` tool, which leaves the item's partition list at
  `apple-tool:` (read from the live keychain's ACL dump); a Security-framework read from the
  signed app is therefore asked for the login password, and the "Always Allow" grant is wiped when
  Claude Code rewrites the item at the next token refresh (`mdat` moved the same afternoon, the
  list stayed `apple-tool:` only). `ClaudeKeychain.accessToken` now reads through
  `/usr/bin/security find-generic-password -w` first — silent for that partition, killed after
  five seconds, fresh on every call so a refreshed token is used — and keeps the framework read as
  the fallback. `ClaudeKeychainTests` covers the tool's output shape and the missing-item case.
- **Two stats added, not fixed:** `UsageReport.longestSession` (a transcript's first message instant to
  its last — `UsageRecord.instant` is kept for it; a transcript with no timestamps still counts as a
  session but has no span) and `mostActiveDay` (the local day with the most tokens, the earliest on a
  tie). `UsageSessionStatsTests`; mutants shortest-for-longest and least-for-most fail only that test.

## Known non-issues (do not "fix" these again)

- `ClaudeQuotaCache.lastValue` has no caller in Sidewatch — public API, kept on purpose.
- `TurnBoundary.id` collapses two turns opened by the same text within one clock minute — documented on
  the property; fixing it means a full-precision timestamp on `TimelineEvent`.

## History

- 17 Sep 2026 — full audit (app + all 20 libraries), Claude with David.
- 18 Sep 2026 — logic review (every source and test file, line by line), Claude with David.
- 18 Sep 2026 — `ModelPricing` by generation from the published page; `ClaudeQuota` reads the `limits` array,
  `spend` and `seven_day_breakdown` (see "Usage prices and plan limits" above).
- 18 Sep 2026 — `UsageReport.longestSession` / `mostActiveDay`.
- 18 Sep 2026 — `ClaudeKeychain` reads through the `security` tool first (no prompt); framework read as fallback.
- 22 Sep 2026 — `TurnEffort` and `TurnBoundary.effort(in:)` / `plan(in:)` moved in from Sidewatch's `AgentTurnNode` (the outline row keeps only its drawing); `TurnEffortTests`. AGENTS.md re-mirrored from CLAUDE.md (it had drifted: Extensions, Monitoring and ClaudeQuota+Display were missing).
