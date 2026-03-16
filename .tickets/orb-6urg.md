---
id: orb-6urg
status: closed
deps: [orb-gbms, orb-f161]
links: []
created: 2026-03-16T19:56:08Z
type: task
priority: 1
assignee: coopwilliams
tags: [orchestrator, core]
---
# Orchestrator script

Script (scripts/orchestrator.sh or similar) that the dispatcher invokes after creating tickets. Reads open tk tickets, spawns one subagent per ticket in parallel. Each subagent gets its prompt from the template + the ticket's block content. For #∑ tags, passes the full file. Waits for all subagents to complete, then releases TROOTHLOCK. Handles subagent failures by marking the block with #¡ and closing the ticket with a note.

