#!/usr/bin/env bash
# dispatcher.sh — Troothfairy vault tag dispatcher
#
# Triggered by fswatch when .md files change in the vault.
# Scans for open user tags, groups them by file, and creates
# one `tk` ticket per file via the tk CLI.
#
# Requires: bash 3.2+ (compatible with macOS system bash), grep, awk, sort
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
    {
        grep -rn --include='*.md' -F "$TAG_F" "$VAULT_DIR" 2>/dev/null || true
        grep -rn --include='*.md' -F "$TAG_D" "$VAULT_DIR" 2>/dev/null || true
        grep -rn --include='*.md' -F "$TAG_S" "$VAULT_DIR" 2>/dev/null || true
        grep -rn --include='*.md' -F "$TAG_C" "$VAULT_DIR" 2>/dev/null || true
    } | sort -t: -k1,1 -k2,2n
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
# Group tags by file using temp files.
#
# Strategy (bash 3.2-compatible, no associative arrays):
#   - A manifest file lists each unique file path that has tags, one per line.
#   - For each tagged file, a sidecar temp file accumulates the description.
#   - Sidecar files are named by MD5/sha hash of the file path to avoid
#     collisions and filesystem-unfriendly characters.
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"; rm -f "$LOCKFILE"' EXIT

MANIFEST="${WORK_DIR}/manifest"
touch "$MANIFEST"

# Returns a safe filename derived from a string (sha256, first 16 hex chars)
safe_key() {
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
}

while IFS= read -r result_line; do
    # result_line format:  /path/to/file.md:42:  - #ƒ do something
    file_path="${result_line%%:*}"
    remainder="${result_line#*:}"
    line_num="${remainder%%:*}"
    line_content="${remainder#*:}"

    # Determine tag type label
    tag_type="unknown"
    if [[ "$line_content" == *"$TAG_F"* ]]; then
        tag_type="ƒ (explicit instruction)"
    elif [[ "$line_content" == *"$TAG_D"* ]]; then
        tag_type="∆ (evaluate and enrich)"
    elif [[ "$line_content" == *"$TAG_S"* ]]; then
        tag_type="∑ (evaluate with full file context)"
    elif [[ "$line_content" == *"$TAG_C"* ]]; then
        tag_type="© (validate/check)"
    fi

    # Extract the block for this tag
    block_content=$(extract_block "$file_path" "$line_num")

    # Derive sidecar file path for this source file
    key=$(safe_key "$file_path")
    sidecar="${WORK_DIR}/${key}.desc"

    # Register this file in the manifest if not already present
    if ! grep -qF "$file_path" "$MANIFEST" 2>/dev/null; then
        printf '%s\n' "$file_path" >> "$MANIFEST"
        # Write the sidecar header with the source path so we can retrieve it
        printf '%s\n' "$file_path" > "${WORK_DIR}/${key}.path"
    fi

    # Append tag entry to this file's description sidecar
    {
        printf '%s\n' "--- Tag #${tag_type} at line ${line_num} ---"
        printf '%s\n' "$block_content"
        printf '\n'
    } >> "$sidecar"

done <<< "$GREP_RESULTS"

# ---------------------------------------------------------------------------
# Create one tk ticket per file
# ---------------------------------------------------------------------------
ticket_count=0

while IFS= read -r file_path; do
    [[ -z "$file_path" ]] && continue

    key=$(safe_key "$file_path")
    sidecar="${WORK_DIR}/${key}.desc"
    filename=$(basename "$file_path")
    description=$(cat "$sidecar")

    tk create "Troothfairy: ${filename}" \
        -t task \
        -d "$description" \
        --tags troothfairy,auto

    ticket_count=$((ticket_count + 1))
done < "$MANIFEST"

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
