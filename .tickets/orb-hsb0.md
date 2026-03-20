---
id: orb-hsb0
status: closed
deps: []
links: []
created: 2026-03-17T01:32:58Z
type: task
priority: 2
assignee: coopwilliams
tags: [enhancement]
---
# System prompt file injection

Let users configure files always included in every subagent system prompt via config.yaml (system_prompt_files list). Orchestrator reads these and appends content to the system prompt. Paths relative to repo root. Useful for personal style guides, domain glossaries, or standing instructions.


## Notes

**2026-03-20T04:19:44Z**

Closing as won't do. Prompt injection and system-prompt handling now moved to the structured policy/template path in orb-1mod rather than a separate prompt-file injection ticket.
