---
id: orb-y21p
status: open
deps: []
links: []
created: 2026-03-20T02:34:05Z
type: task
priority: 2
assignee: coopwilliams
---
# Extract deterministic patch application into a patch engine module

# Pull deterministic file mutation out of orchestrator flow

As Troothfairy moves to block-level jobs and structured patch intents, deterministic file mutation should live in a dedicated patch engine rather than being embedded in `scripts/orchestrator.sh`. This keeps reasoning/generation concerns separate from file surgery and reduces protocol duplication.

## Scope

- Introduce a dedicated patch-application module/script responsible for:
  - completion-tag swaps
  - failure marker placement
  - insertion of nested response bullets
  - no-op success handling
  - created-file link insertion if needed
- Make the orchestrator hand validated patch intents to the patch engine rather than editing files directly.
- Support per-file serialized application and re-resolution against fresh file contents at apply time.
- Keep the patch engine deterministic, auditable, and idempotent enough for retries.

## Acceptance criteria

- Patch logic is isolated behind a clear interface.
- Orchestrator no longer owns low-level file mutation details.
- Patch behavior is testable independently from model execution.
- Mixed-route jobs in one file can be applied through the same patch engine safely.

