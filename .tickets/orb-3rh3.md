---
id: orb-3rh3
status: open
deps: []
links: []
created: 2026-03-20T03:04:28Z
type: bug
priority: 2
assignee: coopwilliams
---
# Prevent user-tag leakage into agent responses and created files

# Deterministically block user-trigger tags from appearing in agent output

Agent responses and agent-created files must never contain live user-trigger tags such as `#ƒ`, `#∆`, `#∑`, `#©`, or `#$`. If those tags leak into inserted response bullets or into files created by a local/bash-capable agent, they can create accidental re-triggering, ambiguous state, or broken protocol behavior. This should not rely on prompt compliance alone.

## Problem

Even if the model is instructed not to emit user tags, a backend can still accidentally include them in:
- inserted response bullets
- degraded/failure explanations
- created markdown files
- excerpt output or other local-agent generated content

Because these tags are executable triggers in the vault, leakage is a protocol bug and should be sanitized deterministically before content is written.

## Scope

- Add deterministic sanitization for all user-trigger tags in orchestrator-managed inserted content
- Add deterministic sanitization for markdown files created by agents before those files are finalized in the vault
- Replace leaked user tags with a safe descriptive marker rather than silently dropping them
- Make the replacement explicit enough that the user can see that the agent attempted to emit a trigger tag
- Cover both normal responses and local/bash-agent file outputs

## Suggested behavior

If agent output contains a live user tag, replace it with a safe literal marker such as:
- `[agent-emitted user tag: #∆]`
- or another non-triggering descriptive token

The exact replacement can be decided in implementation, but it must:
- never trigger the watcher
- preserve enough information for debugging
- be applied deterministically in code, not left to prompting

## Acceptance criteria

- Inserted response bullets cannot contain live user-trigger tags
- Agent-created markdown files cannot contain live user-trigger tags without sanitization
- Sanitization runs even if the model ignores instructions
- Tests cover every trigger tag and both response/file-creation paths
- The user can tell from the sanitized output that the agent attempted to emit a trigger tag

