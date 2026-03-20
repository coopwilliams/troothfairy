---
id: orb-1mod
status: open
deps: []
links: []
created: 2026-03-20T02:34:05Z
type: feature
priority: 2
assignee: coopwilliams
---
# Single source of truth for tag policy and prompt rendering

# Centralize tag/route policy and generate prompts from structured config

Troothfairy currently duplicates protocol rules across `scripts/orchestrator.sh`, `scripts/prompts/subagent-system.md`, tests, and developer docs. Tag semantics, completion-tag behavior, tool permissions, and route assumptions can drift because there is no machine-readable source of truth.

Create a single structured policy definition, likely in a config file such as `config/tags.yaml` or `config/routes.yaml`, and make dispatcher, orchestrator, prompt rendering, and tests derive behavior from it.

## Scope

- Define a machine-readable schema for each one-character user tag:
  - semantic meaning
  - execution route
  - completion-tag behavior
  - allowed/forbidden capabilities
  - default model
  - full-file-context requirement
  - whether empty responses are valid
- Replace hard-coded tag policy in shell scripts with lookups against this config.
- Introduce prompt templates that are rendered from the structured policy plus per-job data, rather than hand-maintained duplicated prose.
- Reduce prompt contents to agent-relevant behavior only; deterministic file-surgery rules should live in code, not prose.
- Update docs/tests to consume or validate against the same policy source.

## Why templates help

Templates are useful here because the prompt has a stable structure but variable policy inputs. For example, a route-specific system template can render the correct capability and output-contract instructions without hard-coding them in multiple files, and a job template can render block metadata consistently for every execution route.

## Acceptance criteria

- One source of truth exists for tag policy and route policy.
- Orchestrator behavior matches the structured policy rather than duplicated string logic.
- Prompt rendering uses templates plus structured data.
- Tests fail when config and rendered prompt behavior diverge.
- Adding or changing a tag no longer requires hand-editing multiple contradictory files.


## Notes

**2026-03-20T02:36:48Z**

Implementation sketch for structured policy and prompt rendering:

Recommended files:
- `config/tags.yaml` for tag semantics and execution policy
- `scripts/prompts/system.mustache.md` (or similar) for route-aware system prompt rendering
- `scripts/prompts/job.mustache.md` for per-job user prompt rendering
- optional `config/result-schema.json` for the structured result contract used by generation backends

Recommended `config/tags.yaml` shape:

```yaml
schema_version: 1

routes:
  local-agent:
    backend: claude-cli
    allow:
      - bash
      - read
      - write
    deny:
      - web_search
      - web_fetch
    deterministic_patching: true
    direct_vault_mutation: false

  api-search:
    backend: api
    allow:
      - thinking
      - web_search
      - web_fetch
    deny:
      - bash
      - read
      - write
    deterministic_patching: true
    direct_vault_mutation: false

  hybrid:
    backend: reserved
    allow:
      - bash
      - web_search
      - web_fetch
    deny: []
    deterministic_patching: true
    direct_vault_mutation: false
    enabled: false
    disabled_reason: >-
      Stub route. Do not execute until a safe design exists.

tags:
  "ƒ":
    route: api-search
    meaning: explicit_instruction
    completion:
      success: "º"
      degraded: "º"
    needs_full_file: false
    allow_empty_response: false
    default_model: sonnet

  "∆":
    route: api-search
    meaning: evaluate_and_enrich
    completion:
      success: "º"
      degraded: "º"
    needs_full_file: false
    allow_empty_response: false
    default_model: sonnet

  "∑":
    route: api-search
    meaning: evaluate_with_full_file_context
    completion:
      success: "º"
      degraded: "º"
    needs_full_file: true
    allow_empty_response: false
    default_model: sonnet

  "©":
    route: api-search
    meaning: fact_check
    completion:
      correct: "™"
      corrected: "≠"
      degraded: "≠"
    needs_full_file: false
    allow_empty_response: true
    default_model: sonnet

  "$":
    route: local-agent
    meaning: explicit_instruction_with_local_tools
    completion:
      success: "º"
      degraded: "º"
    needs_full_file: false
    allow_empty_response: false
    default_model: haiku
```

Recommended structured result schema shape (whether kept in YAML or JSON Schema):

```json
{
  "schema_version": 1,
  "job_id": "string",
  "tag": "∆",
  "outcome": "success | no_op_success | corrected | degraded",
  "completion_tag": "º",
  "append_failure_marker": false,
  "response_bullets": [
    {
      "tag": "#Ω∆",
      "text": "Correct. Self-attention ...",
      "children": [
        {
          "tag": "#¬",
          "text": "https://... — source description"
        }
      ]
    }
  ],
  "created_files": [
    {
      "path": "_EXCERPTS/topic/file.md",
      "wikilink": "[[_EXCERPTS/topic/file|file]]"
    }
  ]
}
```

Recommended template split:

1. `system.mustache.md`
   Purpose: render route-specific capability and output-contract instructions from policy data.

2. `job.mustache.md`
   Purpose: render per-block job data consistently: file path, line number, tagged line, block text, optional full-file text.

Prompt rendering rules:
- Templates should consume structured policy and structured job data only.
- Deterministic patching rules belong in code and schema docs, not prompt prose.
- Prompt text should describe only what the backend must decide, not how the orchestrator mutates files.

Implementation guidance:
- Start with a tiny renderer; shell + envsubst or awk templating is fine if kept simple. No need for a large templating dependency.
- Add tests that load `config/tags.yaml` and verify every tag renders into prompt context and maps to a deterministic patch contract.
- Keep docs like `CLAUDE.md` explanatory; they should reference the config as source of truth, not restate it in full.
