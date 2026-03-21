---
id: orb-9be9
status: closed
deps: []
links: []
created: 2026-03-20T02:34:05Z
type: task
priority: 2
assignee: coopwilliams
---
# Version block-job payloads and structured result schemas

# Add explicit schema versioning for block jobs and structured results

Block-level jobs and structured result payloads will become an internal protocol between dispatcher, orchestrator, and execution backends. That protocol should be versioned explicitly so future refactors can evolve safely and stale jobs can be detected rather than misinterpreted.

## Scope

- Add a schema version field to block-job payloads.
- Add a schema version field to structured result / patch-intent payloads.
- Make orchestrator validate versions before processing.
- Define failure behavior for unknown or stale versions.
- Cover version handling in tests.

## Acceptance criteria

- Internal job/result protocol is versioned explicitly.
- Orchestrator rejects unsupported payload versions clearly.
- Future schema evolution does not require fragile implicit assumptions.

