---
id: orb-3cpl
status: open
deps: []
links: []
created: 2026-03-20T03:59:22Z
type: bug
priority: 2
assignee: coopwilliams
---
# Handle single-hit excerpt searches without ad hoc file creation

# Fix excerpt-text edge case when the initial search produces only one result chunk

There is an edge case in the excerpt workflow where the initial text search yields only one result / one chunk to evaluate. In that case, the current flow can fall off the normal split-and-move path, and the agent may improvise by creating its own excerpt file directly. That is not allowed. Excerpt file creation should remain deterministic and follow the same chunk pipeline regardless of whether there is one result or many.

## Problem

The excerpt-text workflow assumes there will be multiple chunks to split and evaluate. When there is only one result, the agent can end up bypassing the intended move-only flow and creating a file itself. That breaks the contract that chunk files are moved verbatim and that file creation is deterministic.

## Scope

- Trace the single-result path in the excerpt workflow
- Ensure a one-result search still produces a proper split artifact and goes through the normal evaluation/move pipeline
- Prevent agents from improvising ad hoc excerpt file creation in this case
- Keep output behavior consistent whether there are 0, 1, or many matching chunks
- Add tests or a reproducible fixture for the single-result case

## Acceptance criteria

- Single-hit searches produce a deterministic split artifact
- If the single chunk is accepted, it is moved into `_EXCERPTS` through the normal pipeline
- Agents do not create excerpt files directly as a fallback for the one-result case
- The workflow behaves consistently for 0, 1, and N result chunks

