---
id: orb-umwm
status: closed
deps: []
links: []
created: 2026-03-18T00:30:47Z
type: bug
priority: 2
assignee: coopwilliams
tags: [troothfairy, excerpt-text, bug]
---
# Bug: excerpt page number in filename instead of frontmatter

Excerpt files are being named like `patterson-slavery-social-death-p259.md` with the page number in the filename. Page numbers should only appear in the frontmatter as `page_start` / `page_end` tags. Filenames should be descriptive slugs without page numbers.

Root cause: the subagent is ignoring the awk splitter output (which already has page_start/page_end in frontmatter) and recreating files with its own naming scheme.

