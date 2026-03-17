#!/usr/bin/env bash
# orchestrator.sh — Troothfairy subagent orchestrator
#
# Reads open troothfairy tickets created by the dispatcher, spawns one
# subagent (via the claude CLI) per ticket in parallel, waits for all to
# finish, then closes successful tickets or adds a failure note to others.
#
# Invoked by the dispatcher after it has filed all tickets for a run.
# Does NOT manage TROOTHLOCK — that is the dispatcher's responsibility.
#
# Usage: orchestrator.sh [vault_dir]
#   vault_dir  Path to the Obsidian vault (default: ./orb-vault)
#              Used to locate full file paths when the ticket only has the
#              basename.
#
# Requires: bash 3.2+, claude CLI, tk CLI

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VAULT_DIR="${1:-${REPO_ROOT}/orb-vault}"

SYSTEM_PROMPT_FILE="${SCRIPT_DIR}/prompts/subagent-system.md"
BLACKLIST_FILE="${REPO_ROOT}/sourcing/SOURCING-BLACKLIST.md"
WHITELIST_FILE="${REPO_ROOT}/sourcing/SOURCING-WHITELIST.md"

# ---------------------------------------------------------------------------
# Status directory for SwiftBar / external monitoring
# ---------------------------------------------------------------------------
source "${SCRIPT_DIR}/lib/config.sh" 2>/dev/null || true
STATUS_DIR="$(get_config status_dir /tmp/troothfairy-status 2>/dev/null || echo /tmp/troothfairy-status)"
mkdir -p "$STATUS_DIR"

# ---------------------------------------------------------------------------
# Vault-scoped tk: run tk commands from inside the vault so tickets
# are stored in $VAULT_DIR/.tickets/ (not the repo's .tickets/).
# ---------------------------------------------------------------------------
vtk() { (cd "$VAULT_DIR" && tk "$@"); }

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
    echo "orchestrator: system prompt not found: $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
if [[ ! -d "$VAULT_DIR" ]]; then
    echo "orchestrator: vault directory not found: $VAULT_DIR" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Load sourcing lists
# ---------------------------------------------------------------------------
BLACKLIST_CONTENT=""
if [[ -f "$BLACKLIST_FILE" ]]; then
    BLACKLIST_CONTENT=$(cat "$BLACKLIST_FILE")
fi

WHITELIST_CONTENT=""
if [[ -f "$WHITELIST_FILE" ]]; then
    WHITELIST_CONTENT=$(cat "$WHITELIST_FILE")
fi

# ---------------------------------------------------------------------------
# Load and patch the system prompt:
#   Replace the two runtime-injection placeholders with actual content.
# ---------------------------------------------------------------------------
RAW_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")

# Replace blacklist placeholder
SYSTEM_PROMPT="${RAW_SYSTEM_PROMPT//'[blacklist will be injected at runtime]'/$BLACKLIST_CONTENT}"

# Replace whitelist placeholder
SYSTEM_PROMPT="${SYSTEM_PROMPT//'[whitelist will be injected at runtime]'/$WHITELIST_CONTENT}"

# ---------------------------------------------------------------------------
# Fetch open troothfairy tickets
# ---------------------------------------------------------------------------
# tk list outputs one ticket ID per line (or a table; we filter to IDs).
# We use --status=open and --tags=troothfairy to scope the query.
TICKET_IDS=$(vtk list --status=open --tags=troothfairy 2>/dev/null | awk '{print $1}' | grep -E '^[a-zA-Z0-9_-]+$' || true)

if [[ -z "$TICKET_IDS" ]]; then
    echo "orchestrator: no open troothfairy tickets. Nothing to do."
    exit 0
fi

echo "orchestrator: found tickets:"
echo "$TICKET_IDS"

# ---------------------------------------------------------------------------
# Work directory for per-subagent temp files
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
# Helper: find_file_in_vault <basename>
#
# Searches the vault directory for a .md file matching the given basename.
# Prints the first match (full path). Exits non-zero if not found.
# ---------------------------------------------------------------------------
find_file_in_vault() {
    local basename="$1"
    # Use find to locate the file; restrict to .md files under the vault.
    local match
    match=$(find "$VAULT_DIR" -type f -name "$basename" 2>/dev/null | head -1)
    if [[ -z "$match" ]]; then
        return 1
    fi
    printf '%s\n' "$match"
}

# ---------------------------------------------------------------------------
# Helper: parse_tag_type_char <tag_type_label>
#
# Extracts the unicode tag character from labels like:
#   "ƒ (explicit instruction)"
#   "∆ (evaluate and enrich)"
#   "∑ (evaluate with full file context)"
#   "© (validate/check)"
# Returns the first (unicode) character before the space.
# ---------------------------------------------------------------------------
parse_tag_type_char() {
    # The label starts with the tag character followed by a space
    printf '%s' "$1" | cut -c1
}

# ---------------------------------------------------------------------------
# Process each ticket: build subagent prompts, launch in background
# ---------------------------------------------------------------------------
declare -a PIDS=()
declare -a TICKET_ID_ARRAY=()
declare -a STATUS_FILES=()
declare -a ACTIVE_DESCS=()

while IFS= read -r ticket_id; do
    [[ -z "$ticket_id" ]] && continue

    # ---- Get full ticket description via tk show ----
    ticket_body=$(vtk show "$ticket_id" 2>/dev/null) || {
        echo "orchestrator: could not fetch ticket $ticket_id, skipping" >&2
        continue
    }

    # ---- Extract the file basename from the ticket title ----
    # Title format: "Troothfairy: <filename>"
    ticket_title=$(printf '%s\n' "$ticket_body" | grep -m1 'Troothfairy:' | sed 's/.*Troothfairy: *//')
    if [[ -z "$ticket_title" ]]; then
        # Fallback: try the first line of the body that looks like a title
        ticket_title=$(printf '%s\n' "$ticket_body" | head -1)
    fi

    # Strip all leading/trailing whitespace
    ticket_title="$(printf '%s' "$ticket_title" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    file_basename="${ticket_title}"

    # ---- Locate the full file path in the vault ----
    file_path=$(find_file_in_vault "$file_basename") || {
        echo "orchestrator: could not locate file '$file_basename' in vault for ticket $ticket_id, skipping" >&2
        continue
    }

    # ---- Extract the description block (everything after the title line) ----
    # tk show format may vary; we capture everything that looks like tag entries.
    # Tag entry lines begin with "--- Tag #"
    description=$(printf '%s\n' "$ticket_body" | awk '/^--- Tag #/{found=1} found{print}')

    if [[ -z "$description" ]]; then
        echo "orchestrator: ticket $ticket_id has no tag entries in description, skipping" >&2
        continue
    fi

    # ---- Determine whether any tag is #∑ (needs full file context) ----
    needs_full_file=false
    if printf '%s\n' "$description" | grep -qF '∑'; then
        needs_full_file=true
    fi

    # ---- Build the user prompt ----
    # Start with file identification
    user_prompt="You are processing the Obsidian vault file: ${file_path}

"

    # Optionally include the full file content for #∑ tags
    if [[ "$needs_full_file" == "true" ]] && [[ -f "$file_path" ]]; then
        file_content=$(cat "$file_path")
        user_prompt+="Full file content (for #∑ context):
\`\`\`
${file_content}
\`\`\`

"
    fi

    user_prompt+="Process the following tagged blocks in the file. For each block:
- Edit the file in place (do NOT output a diff or explanation — make the actual file changes using your tools).
- Replace the user tag with the correct completion tag per the instructions in your system prompt.
- Add your response as a bullet nested one indent level under the user's tagged line.
- Prefix your response with #Ω followed by the original tag character.

Tagged blocks to process:

${description}

Remember: edit the file at ${file_path} directly. Do not output the modified file content as text — use the Edit or Write tools to make changes. Process all blocks listed above.

Sourcing tags directory: ${REPO_ROOT}/sourcing/tags/ — check relevant topic files here before searching the web."

    # ---- Write the user prompt to a temp file (avoids shell quoting issues) ----
    prompt_file="${WORK_DIR}/${ticket_id}.prompt"
    printf '%s' "$user_prompt" > "$prompt_file"

    # Write system prompt to temp file
    system_prompt_file="${WORK_DIR}/${ticket_id}.system"
    printf '%s' "$SYSTEM_PROMPT" > "$system_prompt_file"

    # Status file: subagent writes "0" on success, "1 <message>" on failure
    status_file="${WORK_DIR}/${ticket_id}.status"

    # ---- Build per-tag status descriptions via Claude summarization ----
    # Ask Claude (haiku, cheap/fast) to summarize each tag block as a short
    # imperative command, e.g. "Rec blogs based on existing sources".
    # Format: one line per tag, "#∆ <summary>"
    # Falls back to raw content preview if summarization fails.

    # First, collect tag chars and raw previews as fallback
    tag_chars=()
    raw_previews=()
    while IFS= read -r tag_header; do
        tag_char=$(printf '%s' "$tag_header" | sed 's/^--- Tag #\(.\).*/\1/')
        tag_chars+=("$tag_char")

        content_line=$(printf '%s\n' "$description" | awk -v hdr="$tag_header" '
            found && /^[^ \t]/ { exit }
            found && NF { print; exit }
            $0 == hdr { found=1 }
        ')
        preview=$(printf '%s' "$content_line" | sed 's/^[[:space:]]*-*[[:space:]]*#[^ ]* //')
        if [[ ${#preview} -gt 60 ]]; then
            preview="${preview:0:57}..."
        fi
        raw_previews+=("$preview")
    done < <(printf '%s\n' "$description" | grep '^--- Tag #')

    # Build summarization prompt
    summary_input=""
    for idx in "${!tag_chars[@]}"; do
        summary_input+="Tag #${tag_chars[$idx]}: ${raw_previews[$idx]}"$'\n'
    done

    # Call Claude haiku for a fast cheap summary
    summary_result=$(printf '%s' "$summary_input" | claude \
        --model haiku \
        -p "For each line below, write a 3-8 word imperative command summarizing the task. Output ONLY one line per input, in the exact format: #X summary (where X is the tag character from the input). No extra text.

${summary_input}" \
        --max-budget-usd 0.01 2>/dev/null) || summary_result=""

    # Parse summaries or fall back to raw previews
    active_desc=""
    for idx in "${!tag_chars[@]}"; do
        tc="${tag_chars[$idx]}"
        # Try to find this tag's summary in Claude's output
        matched_line=$(printf '%s\n' "$summary_result" | grep "^#${tc} " | head -1)
        if [[ -n "$matched_line" ]]; then
            active_desc+="${matched_line}"$'\n'
        else
            active_desc+="#${tc} ${raw_previews[$idx]}"$'\n'
        fi
    done

    # Trim trailing newline
    active_desc="${active_desc%$'\n'}"

    # ---- Write active status file ----
    printf '%s\n' "$active_desc" > "${STATUS_DIR}/active-${ticket_id}"

    # ---- Launch subagent in background ----
    (
        subagent_user_prompt=$(cat "$prompt_file")
        subagent_system=$(cat "$system_prompt_file")

        if claude \
            -p "$subagent_user_prompt" \
            --system-prompt "$subagent_system" \
            --allowedTools "Edit,Read,Write,Bash,WebSearch,WebFetch" \
            2>"${WORK_DIR}/${ticket_id}.stderr"; then
            printf '0' > "$status_file"
        else
            exit_code=$?
            stderr_content=$(cat "${WORK_DIR}/${ticket_id}.stderr" 2>/dev/null | head -5 | tr '\n' ' ')
            printf '1 %s' "exit_code=${exit_code} ${stderr_content}" > "$status_file"
        fi
    ) &

    PIDS+=("$!")
    TICKET_ID_ARRAY+=("$ticket_id")
    STATUS_FILES+=("$status_file")
    ACTIVE_DESCS+=("$active_desc")

    echo "orchestrator: launched subagent for ticket $ticket_id (file: $file_basename, pid: $!)"

done <<< "$TICKET_IDS"

# ---------------------------------------------------------------------------
# Wait for all subagents and collect results
# ---------------------------------------------------------------------------
if [[ ${#PIDS[@]} -eq 0 ]]; then
    echo "orchestrator: no subagents were launched."
    exit 0
fi

echo "orchestrator: waiting for ${#PIDS[@]} subagent(s) to finish..."

overall_exit=0

for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    ticket_id="${TICKET_ID_ARRAY[$i]}"
    status_file="${STATUS_FILES[$i]}"
    active_desc="${ACTIVE_DESCS[$i]}"
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Wait for this specific subagent process
    wait "$pid" 2>/dev/null || true

    # Remove active status file
    rm -f "${STATUS_DIR}/active-${ticket_id}"

    # Read status written by subagent
    status_content=""
    if [[ -f "$status_file" ]]; then
        status_content=$(cat "$status_file")
    fi

    # Convert user tags (#∆, #ƒ, etc.) to agent tags (#Ω∆, #Ωƒ, etc.) for history
    history_desc=$(printf '%s' "$active_desc" | sed 's/^#\(.\)/#Ω\1/; s/\n#\(.\)/\n#Ω\1/g')

    if [[ "$status_content" == "0" ]]; then
        # Success — close the ticket and log to history
        printf '%s ✓ %s\n' "$timestamp" "$history_desc" >> "${STATUS_DIR}/history.log"
        if vtk close "$ticket_id" 2>/dev/null; then
            echo "orchestrator: ticket $ticket_id closed (success)"
        else
            echo "orchestrator: warning — could not close ticket $ticket_id" >&2
        fi
    else
        # Failure — add a note, log to history, leave ticket open
        error_detail="${status_content#1 }"
        if [[ -z "$error_detail" ]]; then
            error_detail="subagent exited with non-zero status"
        fi
        note_msg="Failed: ${error_detail}"
        printf '%s ✗ %s (failed)\n' "$timestamp" "$history_desc" >> "${STATUS_DIR}/history.log"
        if vtk add-note "$ticket_id" "$note_msg" 2>/dev/null; then
            echo "orchestrator: ticket $ticket_id left open with failure note: $note_msg"
        else
            echo "orchestrator: warning — could not add note to ticket $ticket_id" >&2
        fi
        overall_exit=1
    fi
done

echo "orchestrator: done."
exit $overall_exit
