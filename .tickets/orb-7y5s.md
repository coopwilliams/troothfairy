---
id: orb-7y5s
status: open
deps: []
links: []
created: 2026-03-18T18:16:57Z
type: feature
priority: 2
assignee: coopwilliams
---
# Scope subagent permissions and skills per user tag

Each user tag (#ƒ, #∆, #∑, #©, #$) should have a defined set of allowed tools and skills, enforced by the orchestrator when building the subagent command. Currently all non-#$ tags get the same default toolset. Tighter scoping reduces attack surface (especially for tags processing web-fetched content) and makes the permission model explicit. E.g. #© (fact-check) probably doesn't need Write, #∆ doesn't need Bash, etc. Define a tag→permissions mapping in config or orchestrator and wire it through.

