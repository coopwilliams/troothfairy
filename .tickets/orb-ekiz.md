---
id: orb-ekiz
status: closed
deps: []
links: []
created: 2026-03-20T03:00:36Z
type: bug
priority: 2
assignee: coopwilliams
---
# Fix excerpt output path to use the Obsidian vault, not the repo

# Excerpt outputs are being written to the repo instead of the active Obsidian vault

The excerpt workflow is still creating `_EXCERPTS` inside the project repo rather than inside the active Obsidian vault. That is the wrong write target. Excerpt files should always be created under the vault path being processed so that generated files live with the note graph and not in the codebase.

## Expected behavior

- Generated excerpt markdown files are written under `<vault>/_EXCERPTS/...`
- Any `#§` links or returned wikilinks are vault-relative and match the actual vault location
- No excerpt output directories are created in the repo root unless the repo itself is intentionally the configured vault

## Likely cause

Current config and prompt wiring appear to treat `./_EXCERPTS` as repo-relative rather than vault-relative. That makes local-tool agents and excerpt logic resolve the write directory against the repo root.

## Scope

- Trace how `_EXCERPTS` write paths are derived today
- Make excerpt output paths resolve relative to the active vault path, not repo root
- Ensure prompt/config guidance given to agents matches the real destination
- Update tests to cover vault-relative excerpt output and link generation
- Avoid breaking cases where the vault path is absolute or outside the repo

## Acceptance criteria

- Excerpt files are written into the processed vault
- Returned links point to the vault-local `_EXCERPTS` path
- No repo-root `_EXCERPTS` directory is created during normal operation
- Tests cover the path resolution behavior

