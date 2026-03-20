---
id: orb-p451
status: open
deps: []
links: []
created: 2026-03-20T02:07:47Z
type: feature
priority: 2
assignee: coopwilliams
---
# Execution routing: block-level jobs and deterministic patch queues

# Refactor Troothfairy from file-scoped agent jobs to block-scoped routed jobs

Troothfairy currently batches all open tags in a file into one ticket in `scripts/dispatcher.sh`, and `scripts/orchestrator.sh` launches one Claude CLI subagent for that whole file. That model makes route separation awkward and unsafe: different tagged blocks in the same file may need different execution pathways, but a single ticket can only be launched with one tool/model contract. It also couples reasoning and file mutation too tightly, especially for web-capable executions.

Refactor the system so the unit of work is a tagged block, not a file. The dispatcher should emit one job per tagged block, with explicit route selection keyed off the one-character user tag. The orchestrator should execute block jobs in parallel, but apply file mutations deterministically through a per-file patch queue so mixed-route blocks in one file do not race.

## Goals

- Support distinct execution pathways keyed directly from the one-character user tags.
- Make deterministic file mutation the default for non-local-agent routes.
- Allow mixed-route tagged blocks in the same file without race conditions.
- Reduce attack surface by making route/tool boundaries explicit.

## Execution model

Introduce three execution pathways:

1. `local-agent`
   - Bash/local tool access allowed
   - No web search or web fetch

2. `api-search`
   - API/model call with thinking and web search allowed
   - No bash/local shell access
   - Returns structured response / patch intent
   - Orchestrator applies file edits deterministically

3. `hybrid`
   - Bash + web capability model
   - Present in the routing model, but initially disabled/stubbed with a clear failure path until a safe design exists

## Required changes

### Dispatcher

- Stop batching by file.
- Emit one ticket/job per tagged block.
- Include enough metadata for deterministic replay:
  - full file path
  - vault-relative path
  - source line number
  - tag character
  - resolved route
  - exact tagged line text
  - extracted block text
  - whether full-file context is required
- Preserve existing block extraction behavior for bullets vs non-bullets.

### Orchestrator

- Route each job based on the one-character user tag.
- Run reasoning/generation jobs in parallel.
- Separate generation from mutation: jobs should produce structured patch intents or structured response payloads rather than editing the vault directly.
- Maintain a per-file patch queue / lock so file edits are serialized per file.
- Apply queued patches in a stable order, recommended: original tagged line number ascending within each file.
- Resolve each patch against fresh file contents at apply time rather than assuming the original snapshot is still current.
- Keep retry behavior clean and auditable: no partial uncontrolled file edits by agents.

### Routing

- Map each one-character user tag to a single execution route.
- Keep tag meaning simple and easy to type; do not require multiple inline route modifiers.
- Clarify whether `#$` is the `local-agent` tag, or whether a different one-character mapping should own that role.
- Stub `hybrid` intentionally rather than accidentally permitting it.

### Deterministic patching

- The orchestrator, not the agent, should own:
  - completion-tag swaps
  - insertion of nested response bullets
  - failure marker placement (`#¡`)
- Structured output must support `#©` no-op success (`#™` with no inserted response) and correction cases (`#≠` with inserted response).
- Patches should be idempotent enough that retries can detect already-processed blocks and avoid corrupting the file.

### Tests

Add or update tests to cover:

- dispatcher creates one ticket/job per tagged block
- route selection is derived from the one-character tag
- mixed-route blocks in the same file are processed correctly
- orchestrator serializes patch application per file
- deterministic patch application remains correct when earlier patches shift later line numbers
- `api-search` path returns structured output and does not mutate files directly
- `local-agent` path has bash but no web
- `hybrid` route fails in a deliberate, visible way

## Notes

This ticket should subsume or depend on:

- `orb-0wpi` (`orchestrator: agent returns response text, orchestrator applies file edits`)
- `orb-7y5s` (`Scope subagent permissions and skills per user tag`)

Recommended implementation direction:

- Treat each block job as producing a patch intent, not file text.
- Use one source of truth for tag metadata and route policy so dispatcher, orchestrator, and prompts do not drift.
- Keep patch application logic centralized and non-LLM-driven.

Success here should also make the prompt layer simpler, because agents no longer need to be told as much about how file surgery works.


**2026-03-20T02:34:05Z**

Add structured output schema to scope:

The generation side should return a validated JSON payload / patch intent schema rather than freeform text. This should be part of P451, not a follow-on. The schema should be rich enough to represent:
- outcome type (success, correction, degraded, no-op success)
- completion tag to apply
- whether `#¡` should be appended
- nested response bullets
- source links
- created files / wikilinks

The orchestrator should validate this payload before queueing deterministic file patches. Prompting and tests should target this schema directly.
