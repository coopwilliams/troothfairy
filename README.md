# Troothfairy 🪄

An Obsidian vault enrichment system powered by Claude. Write notes, tag them, and Troothfairy automatically evaluates, enriches, fact-checks, or follows your instructions — adding context and sources inline.

## Install

Requires macOS with [Homebrew](https://brew.sh) and [Claude Code](https://claude.ai/claude-code).

```bash
git clone <repo-url> && cd orb
./install.sh
```

That's it. You'll see a 🪄 icon in your menu bar.

## Usage

Write notes in your Obsidian vault using bullet points. Add a tag at the start of any bullet to trigger Troothfairy:

| Tag | Shortcut | What it does |
|-----|----------|-------------|
| `#ƒ` | alt-f | Follow an explicit instruction |
| `#∆` | alt-j | Evaluate your assertion, add context and sources |
| `#∑` | alt-w | Same as `#∆` but reads the entire file for context |
| `#©` | alt-g | Fact-check: pass silently or correct |
| `#$` | shift-4 | Explicit instruction with shell/Bash access (runs on haiku) |

Save the file. Troothfairy detects the change, creates one job per tagged block, asks a model to return structured JSON, and then applies deterministic edits to the file.

### Example

You write:
```
- #∆ Transformer models use self-attention to weigh the relevance of each token to every other token.
```

Troothfairy produces:
```
- #º Transformer models use self-attention to weigh the relevance of each token to every other token.
    - #Ω∆ Correct. Self-attention computes queries, keys, and values for each token...
        - #¬ https://arxiv.org/abs/1706.03762 — "Attention Is All You Need", Vaswani et al.
```

### Completion tags

After processing, user tags are replaced with completion tags:

| Tag | Meaning |
|-----|---------|
| `#º` | Processed (for `#ƒ`, `#∆`, `#∑`, `#$`) |
| `#™` | Fact-checked and correct (for `#©`) |
| `#≠` | Fact-checked with correction (for `#©`) |
| `#¡` | Agent failed or gave a degraded response (appears after the completion tag) |

### Agent tags in responses

| Tag | Meaning |
|-----|---------|
| `#Ω` | Agent response (followed by original tag char, e.g. `#Ω∆`) |
| `#¬` | Source link |
| `#§` | Linked markdown file created by the agent |

## Menu bar

The 🪄 icon in your menu bar shows:
- **White dot**: daemon running, idle
- **Green dot**: subagents actively processing
- **Red dot**: daemon stopped

Click it to stop/start, view active and recent jobs, or open the vault in Obsidian. Stopping the watcher also clears active job state and auto-closes any still-open Troothfairy tickets.

## Configuration

Edit `config.yaml` in the repo root:

```yaml
vault_path: ./orb-vault          # Backward-compatible single-vault setting
# vaults:                        # Optional multi-vault watcher config
#   - ./orb-vault
#   - /Users/you/Documents/WorkVault
max_recent_jobs: 5               # Recent jobs shown in menu bar
status_dir: /tmp/troothfairy-status
```

If `vaults:` is present, Troothfairy watches every listed vault and the menu bar labels active/recent jobs with the vault they belong to. If `vaults:` is omitted, `vault_path` continues to work as before.

`dirs:` entries are interpreted as follows:
- most relative paths resolve from the repo root
- `./_EXCERPTS` resolves under the active vault being processed, so excerpt files go to `<vault>/_EXCERPTS/...`

Tag and route policy now live in `config/tag_policy.json`. Prompt rendering uses:
- `scripts/prompts/system.tmpl.md`
- `scripts/prompts/job.tmpl.md`

### Excluding files

Add filenames (one per line) to `tf-exclusions.md` to prevent the dispatcher from scanning them:

```
Troothfairy.md
```

### Sourcing

Control which domains the agent links to:
- `sourcing/SOURCING-GUIDE.md` — principles for source selection
- `sourcing/SOURCING-WHITELIST.md` — preferred domains
- `sourcing/SOURCING-BLACKLIST.md` — blocked domains

## Manual control

```bash
# Start/stop the file watcher daemon
./scripts/watch.sh start
./scripts/watch.sh start ./orb-vault
./scripts/watch.sh start ./vault-a ./vault-b
./scripts/watch.sh stop
./scripts/watch.sh restart
./scripts/watch.sh status

# Run the pipeline manually (without the daemon)
./scripts/dispatcher.sh ./orb-vault

# Run tests
./tests/run_tests.sh
```

## Architecture

```
fswatch (file watcher)
  → dispatcher.sh (scans for open tags, creates one tk ticket per tagged block)
    → orchestrator.sh (runs block jobs in parallel, gathers structured results)
      → deterministic patching (applies tag swaps and inserted bullets per file)
```

All inter-process state is managed through `tk` tickets and status files in `/tmp/troothfairy-status/`.
