---
id: orb-ako0
status: open
deps: []
links: []
created: 2026-03-21T18:08:12Z
type: task
priority: 2
assignee: coopwilliams
---
# Change local-agent (#$) default model to sonnet

# Change local-agent (#$) default model to sonnet

Update the local-agent / bash-enabled route so `#$` jobs default to Sonnet instead of the current default model, unless explicitly overridden by modifier tags.

## Goals

- Make `#$` jobs use Sonnet by default
- Preserve explicit model override behavior via `#opus`, `#sonnet`, and `#haiku`
- Ensure docs, tests, and prompt expectations reflect the new default

## Scope

- Update the routing / tag policy for `#$`
- Verify orchestrator behavior still respects explicit model override tags
- Update tests and docs that mention the local-agent default model

## Acceptance criteria

- `#$` jobs default to Sonnet when no explicit model override is present
- Explicit model overrides still work correctly
- Tests and documentation are updated accordingly


