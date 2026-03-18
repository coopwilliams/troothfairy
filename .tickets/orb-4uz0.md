---
id: orb-4uz0
status: open
deps: []
links: []
created: 2026-03-18T00:31:48Z
type: bug
priority: 2
assignee: coopwilliams
tags: [troothfairy, excerpt-text, bug]
---
# Bug: colons in frontmatter values break YAML parsing

Frontmatter values containing colons (e.g. `source: Orlando Patterson, Slavery and Social Death: A Comparative Study`) break YAML parsing because the colon is interpreted as a key-value separator.

Fix: the awk splitter should double-quote all string values in the frontmatter it generates. E.g.:
  filepath: "/Users/.../Some Book: Subtitle.pdf"
  search_string: "become ever|be ever"

This affects the `printf` in the flush() function of the awk splitter in SKILL.md.

