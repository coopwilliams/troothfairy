---
id: orb-kgho
status: closed
deps: []
links: []
created: 2026-03-17T01:33:04Z
type: task
priority: 2
assignee: coopwilliams
tags: [enhancement]
---
# Configurable directory access with permissions

Let users configure arbitrary directories in config.yaml, each with a path and an access permission level (read, write, or read-write). Orchestrator injects configured dirs into the subagent context (via system prompt or --add-dir) and constrains --allowedTools accordingly — read-only dirs get Read/Grep, writable dirs also get Write/Edit. Generalises the existing sourcing/tags/ mechanism to any local knowledge base or working directory.

