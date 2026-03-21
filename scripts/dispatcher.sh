#!/usr/bin/env bash
# dispatcher.sh — Troothfairy vault tag dispatcher
#
# Triggered by fswatch when .md files change in the vault.
# Scans for open user tags and creates one `tk` ticket per tagged block.
#
# Requires: bash 3.2+ (compatible with macOS system bash), grep, awk, sort, jq
#
# Usage: dispatcher.sh [vault_dir]
#   vault_dir  Path to the Obsidian vault (default: ./orb-vault)

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
LOCKFILE="/tmp/TROOTHLOCK"
VAULT_DIR="${1:-./orb-vault}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
EXCLUSIONS_FILE="${REPO_ROOT}/tf-exclusions.md"
ORCHESTRATOR="${ORCHESTRATOR:-${SCRIPT_DIR}/orchestrator.sh}"

# Open user tags (UTF-8 multi-byte unicode characters)
TAG_F='#ƒ'   # alt-f  — explicit instruction
TAG_D='#∆'   # alt-j  — evaluate and enrich
TAG_S='#∑'   # alt-w  — evaluate with full file context
TAG_C='#©'   # alt-g  — validate/check
TAG_BASH='#$' # alt-4  — explicit instruction with shell access

source "${SCRIPT_DIR}/lib/config.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/tag_policy.sh" 2>/dev/null || true

BLOCK_JOB_SCHEMA_VERSION="$(block_job_schema_version)"

# ---------------------------------------------------------------------------
# Vault-scoped tk: run tk commands from inside the vault so tickets
# are stored in $VAULT_DIR/.tickets/ (not the repo's .tickets/).
# ---------------------------------------------------------------------------
vtk() { TICKETS_DIR="${VAULT_DIR}/.tickets" tk "$@"; }

# ---------------------------------------------------------------------------
# TROOTHLOCK: only one dispatcher runs at a time
# ---------------------------------------------------------------------------
if [[ -f "$LOCKFILE" ]]; then
    # Another dispatcher is already running; it will catch all remaining tags
    exit 0
fi

# Create lock and ensure it is removed on exit under any circumstance
touch "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# ---------------------------------------------------------------------------
# Sanity check
# ---------------------------------------------------------------------------
if [[ ! -d "$VAULT_DIR" ]]; then
    echo "dispatcher: vault directory not found: $VAULT_DIR" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: extract_block <file> <start_line_number>
#
# If the tagged line is a bullet (optional leading whitespace, then "- "),
# returns that line plus all lines indented strictly deeper below it, until
# a line at the same or lesser indentation level, a blank line at base
# indentation, or EOF.
# If the tagged line is NOT a bullet, returns just that single line.
# ---------------------------------------------------------------------------
extract_block() {
    local file="$1"
    local start="$2"

    # Read the tagged line (1-indexed → awk NR)
    local tagged_line
    tagged_line=$(awk "NR==$start" "$file")

    # Determine whether the tagged line is a bullet.
    # Match: optional tabs/spaces followed immediately by a dash.
    if [[ "$tagged_line" =~ ^([[:space:]]*)- ]]; then
        local base_indent="${BASH_REMATCH[1]}"
        local base_len="${#base_indent}"

        awk -v start="$start" -v base_len="$base_len" '
        NR < start { next }
        NR == start { print; next }
        {
            # Strip everything from first non-whitespace char to measure indent
            indent = $0
            gsub(/[^ \t].*/, "", indent)
            ind_len = length(indent)

            # Lines indented strictly deeper than base belong to this block
            if (ind_len > base_len) {
                print
                next
            }
            # Same or lesser indentation — block ends here
            exit
        }
        ' "$file"
    else
        # Non-bullet: return only the single tagged line
        printf '%s\n' "$tagged_line"
    fi
}

# ---------------------------------------------------------------------------
# Scan vault for open user tags
# grep -rn outputs:  filepath:lineno:line_content
# Merge results from all four tags and sort by file path then line number.
# ---------------------------------------------------------------------------
GREP_RESULTS=$(
    grep -rn --include='*.md' -F \
        --exclude-dir='.tickets' \
        -e "$TAG_F" -e "$TAG_D" -e "$TAG_S" -e "$TAG_C" -e "$TAG_BASH" \
        "$VAULT_DIR" 2>/dev/null \
    | sort -t: -k1,1 -k2,2n \
    || true
)

# ---------------------------------------------------------------------------
# Filter out excluded files (listed one per line in tf-exclusions.md)
# ---------------------------------------------------------------------------
if [[ -f "$EXCLUSIONS_FILE" ]]; then
    while IFS= read -r excluded; do
        [[ -z "$excluded" ]] && continue
        GREP_RESULTS=$(printf '%s\n' "$GREP_RESULTS" | grep -v "/${excluded}:" || true)
    done < "$EXCLUSIONS_FILE"
fi

if [[ -z "$GREP_RESULTS" ]]; then
    echo "dispatcher: no open tags found. Exiting."
    exit 0
fi

# ---------------------------------------------------------------------------
# Helpers for block-level job tickets.
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"; rm -f "$LOCKFILE"' EXIT
ticket_count=0

extract_tag_char() {
    local line_content="$1"
    if [[ "$line_content" == *'#$'* ]]; then
        printf '$\n'
    elif [[ "$line_content" == *"$TAG_F"* ]]; then
        printf 'ƒ\n'
    elif [[ "$line_content" == *"$TAG_D"* ]]; then
        printf '∆\n'
    elif [[ "$line_content" == *"$TAG_S"* ]]; then
        printf '∑\n'
    elif [[ "$line_content" == *"$TAG_C"* ]]; then
        printf '©\n'
    else
        printf '?\n'
    fi
}

extract_json_payload() {
    perl -CSDA -0ne '
        if (/(\{(?:(?>[^{}]+)|(?1))*\})/s) {
            print $1;
            exit;
        }
    ' <<< "$1"
}

build_job_key() {
    local file_path="$1"
    local line_num="$2"
    local tag_char="$3"
    printf '%s|%s|%s\n' "$file_path" "$line_num" "$tag_char"
}

is_ticket_still_live() {
    local file_path="$1"
    local line_num="$2"
    local tagged_line="$3"

    [[ -f "$file_path" ]] || return 1
    current_line=$(awk "NR==$line_num" "$file_path" 2>/dev/null || true)
    [[ -n "$current_line" ]] || return 1
    [[ "$current_line" == "$tagged_line" ]]
}

OPEN_JOB_KEYS=$(
    vtk list --status=open --tags=troothfairy 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^[a-zA-Z0-9_-]+$' \
    | while IFS= read -r ticket_id; do
        [[ -n "$ticket_id" ]] || continue
        ticket_body=$(vtk show "$ticket_id" 2>/dev/null || true)
        job_json=$(extract_json_payload "$ticket_body")
        [[ -n "$job_json" ]] || continue
        actual_schema_version="$(printf '%s\n' "$job_json" | jq -r '.schema_version // "missing"' 2>/dev/null || printf 'missing\n')"
        if [[ "$actual_schema_version" != "$BLOCK_JOB_SCHEMA_VERSION" ]]; then
            vtk add-note "$ticket_id" "Unsupported block-job payload auto-closed: schema_version=${actual_schema_version}, expected=${BLOCK_JOB_SCHEMA_VERSION}" >/dev/null 2>&1 || true
            vtk close "$ticket_id" >/dev/null 2>&1 || true
            continue
        fi
        file_path="$(printf '%s\n' "$job_json" | jq -r '.file_path // empty')"
        line_number="$(printf '%s\n' "$job_json" | jq -r '.line_number // empty')"
        tag_char="$(printf '%s\n' "$job_json" | jq -r '.tag_char // empty')"
        tagged_line="$(printf '%s\n' "$job_json" | jq -r '.tagged_line // empty')"
        if is_ticket_still_live "$file_path" "$line_number" "$tagged_line"; then
            printf '%s|%s|%s\n' "$file_path" "$line_number" "$tag_char"
        else
            vtk add-note "$ticket_id" "Stale job auto-closed: source tag is no longer present at the recorded file/line" >/dev/null 2>&1 || true
            vtk close "$ticket_id" >/dev/null 2>&1 || true
        fi
    done \
    || true
)

while IFS= read -r result_line; do
    [[ -z "$result_line" ]] && continue

    # result_line format:  /path/to/file.md:42:  - #ƒ do something
    file_path="${result_line%%:*}"
    remainder="${result_line#*:}"
    line_num="${remainder%%:*}"
    line_content="${remainder#*:}"

    tag_char=$(extract_tag_char "$line_content")
    tag_label=$(policy_tag_label "$tag_char")
    route=$(policy_tag_route "$tag_char")
    needs_full_file=$(policy_tag_needs_full_file "$tag_char")
    block_content=$(extract_block "$file_path" "$line_num")
    tagged_line=$(awk "NR==$line_num" "$file_path")
    filename=$(basename "$file_path")
    vault_rel="${file_path#"$VAULT_DIR"}"
    vault_rel="${vault_rel#/}"
    vault_rel="${vault_rel%.md}"
    job_key=$(build_job_key "$file_path" "$line_num" "$tag_char")

    if [[ -n "$OPEN_JOB_KEYS" ]] && printf '%s\n' "$OPEN_JOB_KEYS" | grep -Fxq "$job_key"; then
        continue
    fi

    payload_file="${WORK_DIR}/job-${ticket_count}.json"
    jq -n \
        --argjson schema_version "$BLOCK_JOB_SCHEMA_VERSION" \
        --arg file_path "$file_path" \
        --arg vault_rel "$vault_rel" \
        --arg file_basename "$filename" \
        --argjson line_number "$line_num" \
        --arg tag_char "$tag_char" \
        --arg tag_label "$tag_label" \
        --arg route "$route" \
        --argjson needs_full_file "$needs_full_file" \
        --arg tagged_line "$tagged_line" \
        --arg block_content "$block_content" \
        '{
            schema_version: $schema_version,
            file_path: $file_path,
            vault_rel: $vault_rel,
            file_basename: $file_basename,
            line_number: $line_number,
            tag_char: $tag_char,
            tag_label: $tag_label,
            route: $route,
            needs_full_file: $needs_full_file,
            tagged_line: $tagged_line,
            block_content: $block_content
        }' > "$payload_file"

    vtk create "Troothfairy: ${filename}:${line_num}:#${tag_char}" \
        -t task \
        -d "$(cat "$payload_file")" \
        --tags troothfairy,auto

    if [[ -n "$OPEN_JOB_KEYS" ]]; then
        OPEN_JOB_KEYS="${OPEN_JOB_KEYS}"$'\n'"${job_key}"
    else
        OPEN_JOB_KEYS="${job_key}"
    fi

    ticket_count=$((ticket_count + 1))
done <<< "$GREP_RESULTS"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "dispatcher: created ${ticket_count} ticket(s)."

# ---------------------------------------------------------------------------
# Hand off to the orchestrator if tickets were created
# ---------------------------------------------------------------------------
if [[ "$ticket_count" -gt 0 ]]; then
    echo "dispatcher: invoking orchestrator..."
    "$ORCHESTRATOR" "$VAULT_DIR"
fi
