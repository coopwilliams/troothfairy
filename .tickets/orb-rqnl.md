---
id: orb-rqnl
status: closed
deps: []
links: []
created: 2026-03-18T00:31:02Z
type: bug
priority: 2
assignee: coopwilliams
tags: [troothfairy, excerpt-text, bug]
---
# Bug: agent adding unauthorized frontmatter tags to excerpts

The subagent is adding its own frontmatter tags (e.g. `agent-added: true`, `source: ...`) that aren't part of the excerpt-text skill spec. The skill's awk splitter already generates correct frontmatter with `filepath`, `search_string`, `context_lines`, `page_start`, `page_end`. The agent should copy chunks as-is into the EXCERPT_DIR, not rewrite them.

The skill instructions need to be more explicit: step 5 should say "copy the chunk file verbatim" rather than leaving room for the agent to reformat.

