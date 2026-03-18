---
id: orb-jj6f
status: closed
deps: []
links: []
created: 2026-03-17T01:51:28Z
type: bug
priority: 2
assignee: coopwilliams
---
# Vault .tickets dir causes dispatch loop

The vault's .tickets/ directory contains markdown files with tag characters in them. fswatch picks up changes to these files, and the grep scan finds tags inside them, causing the dispatcher to create tickets for ticket files — creating an infinite loop.

