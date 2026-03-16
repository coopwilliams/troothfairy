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
VAULT_PATH="$(resolve_vault_path)"
WATCH_SH="${SCRIPT_DIR}/watch.sh"

# ---------------------------------------------------------------------------
# Derive vault name for Obsidian URL from the vault directory basename
# ---------------------------------------------------------------------------
VAULT_NAME="$(basename "$VAULT_PATH")"

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
    echo "🪄"
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
    echo "Troothfairy: Paused | color=gray"
fi

# ---------------------------------------------------------------------------
# Toggle button
# ---------------------------------------------------------------------------
if $DAEMON_RUNNING; then
    echo "Pause | bash=${WATCH_SH} param1=stop terminal=false refresh=true"
else
    echo "Start | bash=${WATCH_SH} param1=start param2=${VAULT_PATH} terminal=false refresh=true"
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
            description="$(cat "$f" 2>/dev/null)"
            [[ -z "$description" ]] && continue
            echo "✎ ${description} | color=green"
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
            # Line format: TIMESTAMP STATUS DESCRIPTION
            # STATUS is ✓ or ✗
            timestamp="${line%% *}"
            rest="${line#* }"
            status_char="${rest%% *}"
            desc="${rest#* }"

            # Format the timestamp for display (strip seconds if desired)
            short_ts="${timestamp%%T*} ${timestamp##*T}"
            short_ts="${short_ts%:*}"  # trim seconds

            if [[ "$status_char" == "✓" ]]; then
                echo "✓ ${desc}  ${short_ts} | color=green size=12 font=Menlo"
            elif [[ "$status_char" == "✗" ]]; then
                echo "✗ ${desc}  ${short_ts} | color=red size=12 font=Menlo"
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
echo "Open in Obsidian | bash=/usr/bin/open param1=obsidian://open?vault=${VAULT_NAME} terminal=false"
