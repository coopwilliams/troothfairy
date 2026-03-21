---
id: orb-ki6n
status: closed
deps: []
links: []
created: 2026-03-21T02:25:13Z
type: task
priority: 2
assignee: coopwilliams
---
# Add deterministic file-type formatting rules to excerpt splitting

# Add deterministic file-type formatting rules to excerpt splitting

Add a deterministic formatting layer to the excerpt workflow so split artifacts can be normalized by source file type before any agent evaluation or file moves. The immediate use case is PDF excerpts, where extracted text often contains single newlines inserted by page line wrapping in the middle of sentences.

## Problem

Excerpt chunks currently preserve raw extracted text. For PDFs, this often means sentences are broken by hard line breaks that come from page layout rather than author intent. That makes excerpt files harder to read and less faithful to the original paragraph structure. We want deterministic cleanup for these cases, while preserving real paragraph boundaries.

## Desired behavior

- Introduce a deterministic formatting step in the excerpt split pipeline
- Structure it so formatting rules can be extended by file type in the future
- Start with PDF-specific normalization rules
- For PDFs, collapse single newlines that appear to be line-wrap artifacts inside a paragraph
- Preserve paragraph breaks signaled by blank lines / double newlines
- Keep this logic out of the agent; the agent should receive already-formatted split chunks
- Surface the active formatting rules clearly in the prompt / skill instructions so the agent understands the split artifacts are already normalized deterministically

## Implementation direction

- Add a dedicated formatting-rules module or similar structure so new file-type rules can be added cleanly later
- Run formatting during the split stage of the excerpt workflow, before chunk evaluation and move-only finalization
- Ensure the final excerpt files still come from deterministic split artifacts, not agent-authored file content

## Acceptance criteria

- PDF excerpt chunks are normalized to remove line-wrap newlines within paragraphs
- Blank-line paragraph boundaries are preserved
- The formatting step is deterministic and runs before agent evaluation
- The design is extensible to additional file-type formatting rules later
- Prompt / skill instructions reflect that formatting is applied by deterministic code, not by the agent
- Add tests or a reproducible fixture covering the PDF line-wrap cleanup case


