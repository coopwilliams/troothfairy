---
id: orb-5ckd
status: open
deps: []
links: []
created: 2026-03-21T18:08:12Z
type: task
priority: 2
assignee: coopwilliams
---
# Add optional expanded-context second pass to excerpt-text skill

# Add optional expanded-context second pass to excerpt-text skill

Extend the excerpt-text workflow so users can optionally request expanded context for excerpts that pass the initial filtering stage.

## Problem

The current excerpt-text workflow searches with a relatively small context window due to budget constraints, filters those chunks, and then moves accepted chunks directly into `_EXCERPTS`. This means the final excerpts may include much less surrounding context than the user actually wants, even when only a small number of chunks pass the filter.

## Desired behavior

- Let the user request excerpts with a specific number of context lines
- Use the existing smaller-budget initial search/filter pass to identify matching chunks
- After filtering, optionally perform a second deterministic search pass for accepted chunks only
- In that second pass, re-search each accepted match using a sufficiently unique query string derived from the accepted chunk, and gather the larger requested context window
- Final excerpt files should come from this deterministic second-pass retrieval when expanded context is requested
- If expanded context is not requested, the current single-pass behavior should remain available

## Scope

- Extend the excerpt-text skill contract to support an optional expanded-context / explicit context-line request from the user
- Define how accepted chunks produce deterministic second-pass searches
- Keep the workflow deterministic and compatible with the move-only excerpt pipeline
- Ensure the feature is only activated when the user explicitly asks for expanded context / a specific context-line count
- Add tests or a reproducible fixture covering second-pass expanded-context behavior

## Acceptance criteria

- Users can request excerpts with an explicit context-line count
- Accepted chunks can be re-fetched with a larger context window through a deterministic second pass
- The final output remains deterministic and does not rely on agent-authored excerpt files
- Default behavior remains unchanged when expanded context is not requested
- Tests or fixtures cover the expanded-context path


