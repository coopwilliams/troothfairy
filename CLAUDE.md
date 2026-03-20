# Troothfairy Development Guide

## What this is

Obsidian vault auto-enrichment system. Users tag lines in their vault with unicode tags (#ƒ, #∆, #∑, #©, #$), fswatch detects changes, the dispatcher creates one job per tagged block, and the orchestrator runs generation work in parallel before applying deterministic patches to the vault file.

## Architecture

```
fswatch → watch.sh → dispatcher.sh → orchestrator.sh → claude -p
                                                      ↓
                                            structured JSON result
                                                      ↓
                                           deterministic vault patching
```

- `scripts/watch.sh` — fswatch daemon (start/stop/status)
- `scripts/dispatcher.sh` — scans vault for open tags, creates one `tk` ticket per tagged block, and deduplicates/reconciles stale open jobs
- `scripts/orchestrator.sh` — reads block-job tickets, routes them, requests structured JSON results, and applies deterministic file patches
- `scripts/prompts/subagent-system.md` — subagent system prompt (patched at runtime with blacklist/whitelist/skills); agents return JSON, not file edits
- `scripts/troothfairy.1s.sh` — SwiftBar menu bar plugin
- `config.yaml` — vault path, status dir, directory access permissions
- `scripts/lib/config.sh` — shared config reader
- `tf-exclusions.md` — files the dispatcher should skip
- `.claude/skills/excerpt-text/SKILL.md` — excerpt-text skill (injected into #$ subagent prompts)

## Tag system

### User tags (trigger processing)
- `#ƒ` (alt-f) — explicit instruction → completion: `#º`
- `#∆` (alt-j) — evaluate and enrich → completion: `#º`
- `#∑` (alt-w) — evaluate with full file context → completion: `#º`
- `#©` (alt-g) — fact-check → completion: `#™` (correct) or `#≠` (corrected)
- `#$` (shift-4) — explicit instruction with Bash/shell access, runs on haiku → completion: `#º`

### Modifier tags (inline with user tags)
- `#opus`, `#sonnet`, `#haiku` — override subagent model

### Agent response tags
- `#Ω` — response prefix (e.g. `#Ω∆` for a `#∆` response)
- `#¬` — source URL
- `#§` — linked file (Obsidian wikilink with vault-relative path)
- `#¡` — failure marker (appended after completion tag)

### Rule: user tags are always consumed
Even on failure, the user tag must be replaced with a completion tag. This is non-negotiable.

## Subagent permissions

`#ƒ`, `#∆`, `#∑`, `#©` currently route through `api-search` with `WebSearch,WebFetch` on model `sonnet`.

`#$` routes through `local-agent` with `Read,Write,Bash` and defaults to `haiku`. The excerpt-text skill (from `~/.claude/skills/excerpt-text/SKILL.md`) is injected into the system prompt for `#$` subagents.

Explicit `#opus`, `#sonnet`, or `#haiku` modifiers override the model. Bash is never granted without `#$` — this is a security boundary against prompt injection from web content.

`hybrid` exists in the routing model but is intentionally disabled.

## Directory access (config.yaml `dirs`)

Passed to local-agent jobs as a prompt section. Agents are told to respect access levels.

- `./sourcing/tags` — read (curated topic URLs)
- `/Users/cooperwilliams/Documents/02-books` — read (ebooks, searched with `rga`)
- `/Users/cooperwilliams/Documents/03-papers-essays` — read
- `./_EXCERPTS` — write (resolved under the active vault path, not the repo root)

## Testing

```bash
tests/run_tests.sh        # discovers and runs all test_*.sh files
```

119 assertions across 4 test suites: dispatcher, orchestrator, prompt template, watch.

## Tools / dependencies

- `tk` — ticket CLI (`brew tap wedow/tools && brew install ticket`). Tickets stored in `.tickets/`.
- `fswatch` — file watcher
- `rga` (ripgrep-all) — searches PDFs, EPUBs, etc. Used by excerpt-text skill.
- `swiftbar` — macOS menu bar plugin host

Vault-scoped tickets use `vtk()` wrapper: `TICKETS_DIR="${VAULT_DIR}/.tickets" tk "$@"`

Open tickets in the vault are not watched directly because `.tickets` is excluded from fswatch and dispatcher scans. Stale open block jobs are reconciled and auto-closed by the dispatcher if their recorded tagged line no longer exists at the recorded file/line.

Note: `tk close` takes only one ticket ID at a time. Close multiple with separate calls: `tk close id1 && tk close id2 && tk close id3`

## Key conventions

- The vault (`orb-vault/`) is gitignored. Never commit vault contents.
- Sourcing lists (blacklist/whitelist) are gitignored. Injected into system prompt at runtime.
- `sourcing/tags/` contains per-topic URL files (also gitignored).
- Excerpt files go in `orb-vault/_EXCERPTS/<topic-slug>/` with YAML frontmatter including `filepath`, `page_start`, `page_end`, `search_string`, `context_lines`.
- Newly created vault files must have `agent-added: true` in frontmatter.
- File links in agent responses use Obsidian full-path wikilinks: `[[_EXCERPTS/topic/filename|filename]]`
- Agents return structured JSON results; orchestrator owns completion-tag swaps, `#¡` placement, and inserted response bullets.

## Git workflow
- Test before committing to make sure nothing breaks.
- **Atomic commits**: Each commit should be a single logical change. Don't bundle unrelated changes. If a session touches the dispatcher, the skill, and the system prompt for different reasons, those are separate commits.

## Known issues / gotchas

- **macOS awk**: No capture groups in `match()`. Use `match(line, /pattern/)` then `substr(line, RSTART + RLENGTH)`.
- **macOS bash 3.2**: No associative arrays. Dispatcher uses temp files + sha hashing for grouping.
- **rga `--heading` flag**: Required for the awk splitter to work. Without it, filepaths are prefixed on every line and `--` separators don't appear alone.
- **YAML frontmatter**: strings must be double-quoted or they can break parsing.
- **Tilde in bash**: `~` does not expand inside double quotes. Use `$HOME`.
- **Subagents don't load skills**: Skills from `.claude/skills/` are not available in `-p` mode subagents. The orchestrator must inject skill content into the system prompt explicitly.
- **Perl locale warning in tests**: some shells emit a harmless locale warning for `perl` when `LC_ALL=C.UTF-8`; tests still pass.
