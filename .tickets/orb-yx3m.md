---
id: orb-yx3m
status: closed
deps: []
links: []
created: 2026-03-18T18:16:53Z
type: feature
priority: 2
assignee: coopwilliams
---
# Excerpt-text: parallel subagent batching for chunk evaluation

Replace sequential read-and-judge loop with parallel subagent batches. The supervising agent sends chunks to lightweight subagents that each receive the inclusion criteria and one chunk, returning Yes/No. Supervisor collects results, moves matching chunks to EXCERPT_DIR, then runs the next batch. Should reduce token usage (subagents don't need full skill context) and improve accuracy (each decision is isolated, no drift from reading dozens of chunks sequentially).

