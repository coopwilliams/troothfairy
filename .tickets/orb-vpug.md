---
id: orb-vpug
status: closed
deps: []
links: []
created: 2026-03-17T01:55:25Z
type: bug
priority: 2
assignee: coopwilliams
---
# Stale active status files after job completion

Haiku background job re-creates active-{ticket_id} after the orchestrator cleanup loop has already deleted it, leaving phantom active jobs in the SwiftBar display. Also need to clear any leftover stale files on orchestrator startup.

