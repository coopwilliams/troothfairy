---
id: orb-f161
status: closed
deps: []
links: []
created: 2026-03-16T19:56:02Z
type: task
priority: 1
assignee: coopwilliams
tags: [prompt, core]
---
# Subagent prompt template

Create the parameterized prompt template that each subagent receives. Includes: tag-specific instructions (#ƒ = follow explicit instruction, #∆ = evaluate and enrich, #∑ = same but with full file context, #© = validate or correct), sourcing guide + whitelist/blacklist injected into system prompt, output format rules (response nested one indent under user tag, #Ω+original tag prefix, #¬ for sources, #§ for linked files), and failure handling (mark with #¡, preserve original tag). Template lives at scripts/prompts/ or similar.

