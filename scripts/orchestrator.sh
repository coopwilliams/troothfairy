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
STATUS_DIR="${STATUS_DIR:-$(get_config status_dir /tmp/troothfairy-status 2>/dev/null || echo /tmp/troothfairy-status)}"
mkdir -p "$STATUS_DIR"

# ---------------------------------------------------------------------------
# Vault-scoped tk: run tk commands from inside the vault so tickets
# are stored in $VAULT_DIR/.tickets/ (not the repo's .tickets/).
# ---------------------------------------------------------------------------
vtk() { TICKETS_DIR="${VAULT_DIR}/.tickets" tk "$@"; }

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

    # Vault-relative path (strip vault dir prefix and leading slash), without .md
    vault_rel="${file_path#"$VAULT_DIR"}"
    vault_rel="${vault_rel#/}"
    vault_rel="${vault_rel%.md}"

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

    # ---- Detect per-ticket modifiers from tag block content ----
    # Users can add #bash, #opus, #sonnet, #haiku inline with their tags
    # to override defaults for that ticket's subagent.
    subagent_model="sonnet"
    subagent_tools="Edit,Read,Write,WebSearch,WebFetch"

    if printf '%s\n' "$description" | grep -qiF '#opus'; then
        subagent_model="opus"
    elif printf '%s\n' "$description" | grep -qiF '#haiku'; then
        subagent_model="haiku"
    elif printf '%s\n' "$description" | grep -qiF '#sonnet'; then
        subagent_model="sonnet"
    fi

    if printf '%s\n' "$description" | grep -qiF '#bash'; then
        subagent_tools="Edit,Read,Write,Bash,WebSearch,WebFetch"
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

    # ---- Build per-tag status descriptions from content previews ----
    # Extract the first line of each tag block, strip the tag prefix,
    # and truncate to ~60 chars. Format: #X preview\tvault/rel/path
    active_desc=""
    line_idx=0
    while IFS= read -r desc_line; do
        line_idx=$((line_idx + 1))
        # Only process tag header lines
        case "$desc_line" in
            '--- Tag #'*) ;;
            *) continue ;;
        esac

        # Extract tag char (e.g., ∆) from "--- Tag #∆ (evaluate and enrich) at line 5 ---"
        tag_char=$(printf '%s' "$desc_line" | sed 's/^--- Tag #\(.\).*/\1/')

        # Get the next non-empty line (the actual content)
        content_line=$(printf '%s\n' "$description" | sed -n "$((line_idx + 1)),\$p" | while IFS= read -r cl; do
            if [[ -n "$cl" ]]; then
                printf '%s' "$cl"
                break
            fi
        done)

        # Strip leading whitespace, bullet markers, and tag prefix
        preview=$(printf '%s' "$content_line" | sed 's/^[[:space:]]*-*[[:space:]]*#[^[:space:]]* //')

        # Truncate
        if [[ ${#preview} -gt 60 ]]; then
            preview="${preview:0:57}..."
        fi

        # Fallback if preview is still empty
        if [[ -z "$preview" ]]; then
            preview="$file_basename"
        fi

        active_desc+="#${tag_char} ${preview}"$'\t'"${vault_rel}"$'\n'
    done <<< "$description"

    # Trim trailing newline
    active_desc="${active_desc%$'\n'}"

    # ---- Summarize with Claude haiku (cheap/fast) ----
    # Feed the raw previews to haiku and ask for 3-8 word imperative summaries.
    # On success, overwrite active_desc; on failure, keep raw previews.
    summary_input=""
    while IFS=$'\t' read -r tag_preview _path; do
        [[ -z "$tag_preview" ]] && continue
        summary_input+="${tag_preview}"$'\n'
    done <<< "$active_desc"

    if [[ -n "$summary_input" ]]; then
        summary_result=$(claude \
            --model haiku \
            -p "For each line below, rewrite it as a 3-8 word imperative command. Keep the #X prefix exactly as-is. Output ONLY the rewritten lines, one per input line, nothing else.

${summary_input}" \
            2>/dev/null) || summary_result=""

        # Validate: first line must start with # (reject error messages)
        if [[ -n "$summary_result" ]] && printf '%s' "$summary_result" | head -1 | grep -q '^#'; then
            # Rebuild active_desc with summaries, re-attaching vault paths
            new_desc=""
            idx=0
            while IFS= read -r sum_line; do
                [[ -z "$sum_line" ]] && continue
                # Get the vault path from the corresponding raw line
                raw_line=$(printf '%s\n' "$active_desc" | sed -n "$((idx + 1))p")
                vpath="${raw_line#*$'\t'}"
                new_desc+="${sum_line}"$'\t'"${vpath}"$'\n'
                idx=$((idx + 1))
            done <<< "$summary_result"
            new_desc="${new_desc%$'\n'}"
            if [[ -n "$new_desc" ]]; then
                active_desc="$new_desc"
            fi
        fi
    fi

    # ---- Write active status file ----
    printf '%s\n' "$active_desc" > "${STATUS_DIR}/active-${ticket_id}"

    # ---- Launch subagent in background ----
    # Capture loop variables for the subshell (background fork snapshots these)
    _model="$subagent_model"
    _tools="$subagent_tools"
    (
        subagent_user_prompt=$(cat "$prompt_file")
        subagent_system=$(cat "$system_prompt_file")

        if claude \
            --model "$_model" \
            -p "$subagent_user_prompt" \
            --system-prompt "$subagent_system" \
            --allowedTools "$_tools" \
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

    # Write each tag line as its own history entry, converting user tags
    # (#∆, #ƒ, etc.) to agent tags (#Ω∆, #Ωƒ, etc.)
    if [[ "$status_content" == "0" ]]; then
        while IFS= read -r tag_line; do
            [[ -z "$tag_line" ]] && continue
            history_line=$(printf '%s' "$tag_line" | sed 's/^#\(.\)/#Ω\1/')
            printf '%s ✓ %s\n' "$timestamp" "$history_line" >> "${STATUS_DIR}/history.log"
        done <<< "$active_desc"
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
        while IFS= read -r tag_line; do
            [[ -z "$tag_line" ]] && continue
            history_line=$(printf '%s' "$tag_line" | sed 's/^#\(.\)/#Ω\1/')
            printf '%s ✗ %s\n' "$timestamp" "$history_line" >> "${STATUS_DIR}/history.log"
        done <<< "$active_desc"
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
