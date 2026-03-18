---
id: orb-z19s
status: closed
deps: []
links: []
created: 2026-03-17T20:22:12Z
type: bug
priority: 2
assignee: coopwilliams
---
# Bug: agents sometimes fail to replace user tag with completion tag

## Problem
Subagents sometimes forget to replace the user tag (#ƒ, #∆, #∑, #$, #©) with the completion tag (#º, #™, #≠). This leaves stale open tags in the vault.

## Proposed fix
In the orchestrator, BEFORE spawning the subagent:
1. sed the vault file to replace each user tag with its default completion tag:
   - #ƒ → #º, #∆ → #º, #∑ → #º, #$ → #º, #© → #™
2. Update the user prompt to tell the agent the tag is already replaced — its only job is to add the response underneath.
3. For #© blocks: if the assertion needs correction, the agent changes #™ to #≠.

This eliminates the failure mode entirely — the tag is always consumed, regardless of agent behavior.

