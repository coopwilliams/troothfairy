---
id: orb-sbtg
status: closed
deps: [orb-gbms]
links: []
created: 2026-03-16T19:56:14Z
type: task
priority: 2
assignee: coopwilliams
tags: [infra]
---
# fswatch launch script

Script (scripts/watch.sh) that starts fswatch monitoring the vault directory for .md file changes and pipes events to the dispatcher. Includes: fswatch invocation with appropriate flags (--one-per-batch to debounce rapid saves, -e .obsidian to ignore config), a stop mechanism (PID file or similar), and basic usage instructions.

