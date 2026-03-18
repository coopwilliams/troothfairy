---
id: orb-wck9
status: closed
deps: []
links: []
created: 2026-03-18T00:33:00Z
type: task
priority: 2
assignee: coopwilliams
tags: [troothfairy, excerpt-text, improvement]
---
# Improvement: subagent should use more keywords in ripgrep search

The excerpt-text subagent is using too few keywords in its rga search, missing relevant passages. The skill instructions should guide the agent to:

1. Start with a broad set of keywords/synonyms (e.g. for "women freed from slavery": "women freed|emancipat|manumission|female slave|freedwomen")
2. Only pare down the keyword list if the cost estimate exceeds the reading budget
3. Prefer OR-joined alternatives over a single narrow phrase

Add guidance to the skill's step 2 about keyword variety, and note that narrowing should only happen in the budget-reduction loop (step 3).

