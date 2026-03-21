---
id: orb-ul27
status: open
deps: []
links: []
created: 2026-03-21T01:04:42Z
type: bug
priority: 2
assignee: coopwilliams
---
# Restore descriptive active/recent job summaries in SwiftBar

Since the patch-engine/orchestrator refactor, SwiftBar no longer shows useful job descriptions.

Current behavior:
- Active jobs show only the user tag being processed.
- Recent jobs show only timestamp-heavy entries instead of readable task summaries.

Expected behavior:
- Active jobs should show concise human-readable descriptions of the running work.
- Recent jobs should retain those summaries alongside status and time.
- Restore the previous behavior where a lightweight summarization step produced menu-friendly descriptions for tickets/jobs.

