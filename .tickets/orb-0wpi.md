---
id: orb-0wpi
status: open
deps: []
links: []
created: 2026-03-19T02:45:03Z
type: task
priority: 2
assignee: coopwilliams
tags: [troothfairy]
---
# orchestrator: agent returns response text, orchestrator applies file edits


## Notes

**2026-03-19T02:45:16Z**

Instead of agents using Edit/Read/Write on vault files, have the agent return structured response text via stdout. Orchestrator captures it and applies insertion (awk) and tag swap (sed) deterministically using the line number already in the ticket.

Do NOT strip Edit/Read/Write from agent tools. Instead, prompt the agent to avoid using those tools on the user's vault .md files specifically.

Benefits:
- File surgery is deterministic and auditable
- Prompt injection from web content cannot corrupt vault files via tool calls
- Retry is clean — no partial file state
- #© silent/correct case is trivial: empty output = just do the tag swap

Output format TBD — sentinel-wrapped bullet lines.
