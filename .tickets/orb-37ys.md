---
id: orb-37ys
status: open
deps: []
links: []
created: 2026-03-17T01:32:51Z
type: task
priority: 2
assignee: coopwilliams
tags: [enhancement]
---
# Multi-vault watching

Enable watching multiple Obsidian vaults from a single config. Currently config.yaml has a single vault_path. Support a vaults list with multiple paths. watch.sh spawns one fswatch per vault or watches multiple roots. Dispatcher/orchestrator resolve vault context per event. SwiftBar shows which vault each job belongs to. Maintain backward compat with existing single vault_path key.

