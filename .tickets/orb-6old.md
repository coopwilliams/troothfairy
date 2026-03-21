---
id: orb-6old
status: closed
deps: []
links: []
created: 2026-03-20T02:34:05Z
type: task
priority: 2
assignee: coopwilliams
---
# Add consistency tests for tag policy, prompt rendering, and patch contracts

# Add contract tests that catch drift between policy, prompts, and deterministic logic

Once tag/route policy becomes structured, Troothfairy should have tests that verify the rendered prompts, orchestrator behavior, and patch contracts all agree with the machine-readable source of truth. This is specifically to prevent the current class of contradictions where the prompt says one thing and code does another.

## Scope

- Add tests that validate every defined tag has:
  - route mapping
  - completion-tag rule
  - prompt rendering coverage
  - patch-engine behavior coverage
- Add golden or snapshot-style tests for rendered prompts where useful.
- Add contract tests for structured job results / patch intents.
- Fail fast when a tag is added or changed without updating prompt rendering or deterministic handling.

## Acceptance criteria

- Drift between config, prompts, and code is caught by tests.
- Prompt rendering and patch handling are both exercised from the same structured inputs.
- The test suite makes protocol changes explicit instead of silently permitting contradictions.

