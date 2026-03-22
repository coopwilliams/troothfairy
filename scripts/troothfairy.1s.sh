#!/usr/bin/env bash
# troothfairy.1s.sh — SwiftBar plugin for Troothfairy status
#
# Filename encodes refresh interval: refresh every 1 second.
# Place (or symlink) in SwiftBar's plugin directory.

# ---------------------------------------------------------------------------
# Path resolution — handles symlinks from SwiftBar's plugin directory
# ---------------------------------------------------------------------------
REAL_PATH="$(readlink "$0" 2>/dev/null || echo "$0")"
SCRIPT_DIR="$(cd "$(dirname "$REAL_PATH")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Source config helpers
# ---------------------------------------------------------------------------
# shellcheck source=lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"

# ---------------------------------------------------------------------------
# Read config values
# ---------------------------------------------------------------------------
STATUS_DIR="$(get_config status_dir /tmp/troothfairy-status)"
MAX_RECENT="$(get_config max_recent_jobs 5)"
WATCH_SH="${SCRIPT_DIR}/watch.sh"

VAULT_PATHS=()
while IFS= read -r vault_path; do
    [[ -n "$vault_path" ]] || continue
    VAULT_PATHS+=("$vault_path")
done < <(resolve_vault_paths 2>/dev/null || true)

if [[ ${#VAULT_PATHS[@]} -eq 0 ]]; then
    fallback_vault="$(resolve_vault_path 2>/dev/null || true)"
    [[ -n "$fallback_vault" ]] && VAULT_PATHS+=("$fallback_vault")
fi

DEFAULT_VAULT_PATH="${VAULT_PATHS[0]}"
DEFAULT_VAULT_NAME="$(basename "$DEFAULT_VAULT_PATH")"

# ---------------------------------------------------------------------------
# Determine daemon status
# Rely on watch.sh exit code: 0 = running, non-zero = not running
# ---------------------------------------------------------------------------
is_running() {
    bash "$WATCH_SH" status >/dev/null 2>&1
}

if is_running; then
    DAEMON_RUNNING=true
else
    DAEMON_RUNNING=false
fi

# ---------------------------------------------------------------------------
# Menu bar line (first line of output)
# ---------------------------------------------------------------------------
# Check if any subagents are currently active
HAS_ACTIVE=false
if [[ -d "$STATUS_DIR" ]]; then
    for f in "${STATUS_DIR}"/active-*; do
        if [[ -f "$f" ]]; then
            HAS_ACTIVE=true
            break
        fi
    done
fi

if ! $DAEMON_RUNNING; then
    echo "🪄● | color=red"
elif $HAS_ACTIVE; then
    echo "🪄● | color=#00cc00"
else
    echo "🪄●"
fi

# ---------------------------------------------------------------------------
# Dropdown separator
# ---------------------------------------------------------------------------
echo "---"

# ---------------------------------------------------------------------------
# Status line
# ---------------------------------------------------------------------------
if $DAEMON_RUNNING; then
    echo "Troothfairy: Running | color=green"
else
    echo "Troothfairy: Stopped | color=red"
fi

# ---------------------------------------------------------------------------
# Toggle button
# ---------------------------------------------------------------------------
if $DAEMON_RUNNING; then
    echo "Pause | bash=${WATCH_SH} param1=stop terminal=false refresh=true"
else
    echo "Start | bash=${WATCH_SH} param1=start terminal=false refresh=true"
fi

echo "---"

# ---------------------------------------------------------------------------
# Active subagents
# ---------------------------------------------------------------------------
echo "Active Jobs | size=11 color=#888888"

if [[ -d "$STATUS_DIR" ]]; then
    active_files=("${STATUS_DIR}"/active-*)
    # Check whether glob expanded to real files
    if [[ ${#active_files[@]} -gt 0 && -f "${active_files[0]}" ]]; then
        for f in "${active_files[@]}"; do
            [[ -f "$f" ]] || continue
            while IFS=$'\t' read -r desc_text vault_name obs_path; do
                [[ -z "$desc_text" ]] && continue
                if [[ -z "$obs_path" && -n "$vault_name" ]]; then
                    obs_path="$vault_name"
                    vault_name="$DEFAULT_VAULT_NAME"
                fi
                if [[ -z "$vault_name" ]]; then
                    vault_name="$DEFAULT_VAULT_NAME"
                fi
                if [[ -n "$obs_path" ]]; then
                    encoded_vault=$(printf '%s' "$vault_name" | sed 's/ /%20/g')
                    encoded_path=$(printf '%s' "$obs_path" | sed 's/ /%20/g')
                    echo "✎ ${desc_text} | color=green size=12 font=Menlo bash=/usr/bin/open param1=obsidian://open?vault=${encoded_vault}&file=${encoded_path} terminal=false"
                else
                    echo "✎ ${desc_text} | color=green size=12 font=Menlo"
                fi
            done < "$f"
        done
    else
        echo "No active jobs | color=gray"
    fi
else
    echo "No active jobs | color=gray"
fi

echo "---"

# ---------------------------------------------------------------------------
# Recent jobs
# ---------------------------------------------------------------------------
echo "Recent Jobs | size=11 color=#888888"

HISTORY_LOG="${STATUS_DIR}/history.log"

if [[ -f "$HISTORY_LOG" ]]; then
    # Read last N lines; reverse so newest is first (tail -r is macOS-native)
    recent=$(tail -n "$MAX_RECENT" "$HISTORY_LOG" | tail -r 2>/dev/null || tail -n "$MAX_RECENT" "$HISTORY_LOG")
    if [[ -z "$recent" ]]; then
        echo "No history yet | color=gray"
    else
        echo "$recent" | while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # Line format: TIMESTAMP STATUS DESC_TEXT\tVAULT_PATH
            # STATUS is ✓ or ✗
            timestamp="${line%% *}"
            rest="${line#* }"
            status_char="${rest%% *}"
            desc_with_path="${rest#* }"

            # Split desc from vault path on tab
            desc_text="${desc_with_path%%$'\t'*}"
            remainder="${desc_with_path#*$'\t'}"
            if [[ "$remainder" == "$desc_with_path" ]]; then
                vault_name="$DEFAULT_VAULT_NAME"
                obs_path=""
            else
                vault_name="${remainder%%$'\t'*}"
                obs_path="${remainder#*$'\t'}"
                if [[ "$obs_path" == "$vault_name" ]]; then
                    obs_path="$vault_name"
                    vault_name="$DEFAULT_VAULT_NAME"
                fi
            fi

            # Format the timestamp for display
            short_ts="${timestamp%%T*} ${timestamp##*T}"
            short_ts="${short_ts%:*}"  # trim seconds

            # Build click action if we have a path
            click=""
            if [[ -n "$obs_path" ]]; then
                encoded_vault=$(printf '%s' "$vault_name" | sed 's/ /%20/g')
                encoded_path=$(printf '%s' "$obs_path" | sed 's/ /%20/g')
                click=" bash=/usr/bin/open param1=obsidian://open?vault=${encoded_vault}&file=${encoded_path} terminal=false"
            fi

            if [[ "$status_char" == "✓" ]]; then
                echo "✓ ${desc_text}  ${short_ts} | color=green size=12 font=Menlo${click}"
            elif [[ "$status_char" == "✗" ]]; then
                echo "✗ ${desc_text}  ${short_ts} | color=red size=12 font=Menlo${click}"
            else
                echo "${line} | color=gray size=12 font=Menlo"
            fi
        done
    fi
else
    echo "No history yet | color=gray"
fi

echo "---"

# ---------------------------------------------------------------------------
# Open in Obsidian
# ---------------------------------------------------------------------------
if [[ ${#VAULT_PATHS[@]} -le 1 ]]; then
    encoded_vault=$(printf '%s' "$DEFAULT_VAULT_NAME" | sed 's/ /%20/g')
    echo "Open in Obsidian | bash=/usr/bin/open param1=obsidian://open?vault=${encoded_vault} terminal=false"
else
    echo "Open in Obsidian"
    for vault_path in "${VAULT_PATHS[@]}"; do
        vault_name="$(basename "$vault_path")"
        encoded_vault=$(printf '%s' "$vault_name" | sed 's/ /%20/g')
        echo "${vault_name} | bash=/usr/bin/open param1=obsidian://open?vault=${encoded_vault} terminal=false"
    done
fi
