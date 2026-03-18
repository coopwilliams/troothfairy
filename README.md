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

Save the file. Troothfairy detects the change, processes your tags, and edits the file in place.

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
- **No dot**: daemon paused

Click it to pause/start, view active and recent jobs, or open the vault in Obsidian.

## Configuration

Edit `config.yaml` in the repo root:

```yaml
vault_path: ./orb-vault          # Path to your Obsidian vault
max_recent_jobs: 5               # Recent jobs shown in menu bar
status_dir: /tmp/troothfairy-status
```

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
./scripts/watch.sh start ./orb-vault
./scripts/watch.sh stop
./scripts/watch.sh status

# Run the pipeline manually (without the daemon)
./scripts/dispatcher.sh ./orb-vault

# Run tests
./tests/run_tests.sh
```

## Architecture

```
fswatch (file watcher)
  → dispatcher.sh (scans for open tags, creates tk tickets, batches by file)
    → orchestrator.sh (spawns one claude subagent per ticket in parallel)
      → claude CLI (processes tags, edits vault files in place)
```

All inter-process state is managed through `tk` tickets and status files in `/tmp/troothfairy-status/`.
