---
id: orb-gbms
status: closed
deps: []
links: []
created: 2026-03-16T19:55:56Z
type: task
priority: 1
assignee: coopwilliams
tags: [dispatcher, core]
---
# Dispatcher script

Shell script (scripts/dispatcher.sh) triggered by fswatch on .md file saves. Checks TROOTHLOCK — if locked, exits. Otherwise creates lock, greps vault for open user tags (#ƒ #∆ #∑ #©), extracts each block (tagged line + indented children for bullets, single line otherwise), and creates a tk ticket per open tag with file path, line number, tag type, and block content. Releases lock on exit (trap). Batches multiple tags in the same file into a single ticket so one subagent handles all edits to that file.

