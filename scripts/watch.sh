#!/usr/bin/env bash
# watch.sh — Troothfairy fswatch daemon manager
#
# Starts/stops/checks an fswatch process that monitors the Obsidian vault for
# .md file changes and pipes events to the dispatcher.
#
# Usage:
#   watch.sh start [vault_dir]   Start the watcher (vault_dir default: ./orb-vault)
#   watch.sh stop                Stop the watcher
#   watch.sh status              Report whether the watcher is running
#
# Requires: fswatch (https://github.com/emcrisostomo/fswatch)

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${SCRIPT_DIR}/dispatcher.sh"
PIDFILE="${PIDFILE:-/tmp/troothfairy-watch.pid}"

source "${SCRIPT_DIR}/lib/config.sh" 2>/dev/null || true
STATUS_DIR="${STATUS_DIR:-$(get_config status_dir /tmp/troothfairy-status 2>/dev/null || echo /tmp/troothfairy-status)}"

find_bin() {
    local name="$1"
    local candidate
    for candidate in \
        "$(command -v "$name" 2>/dev/null || true)" \
        "/opt/homebrew/bin/${name}" \
        "/usr/local/bin/${name}" \
        "/usr/bin/${name}"; do
        [[ -n "$candidate" && -x "$candidate" ]] && {
            printf '%s\n' "$candidate"
            return 0
        }
    done
    return 1
}

FSWATCH_BIN="${FSWATCH_BIN:-$(find_bin fswatch 2>/dev/null || true)}"
TK_BIN="${TK_BIN:-$(find_bin tk 2>/dev/null || true)}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

die() {
    echo -e "${RED}error${NC}: $*" >&2
    exit 1
}

PIDFILE_PID=""
PIDFILE_VAULT=""

read_pidfile() {
    PIDFILE_PID=""
    PIDFILE_VAULT=""
    [[ -f "$PIDFILE" ]] || return 1

    local pid_line vault_line
    pid_line=$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)
    vault_line=$(sed -n '2p' "$PIDFILE" 2>/dev/null || true)

    if [[ -n "$pid_line" && "$pid_line" == *$'\t'* ]]; then
        PIDFILE_PID="${pid_line%%$'\t'*}"
        PIDFILE_VAULT="${pid_line#*$'\t'}"
    else
        PIDFILE_PID="$pid_line"
        PIDFILE_VAULT="$vault_line"
    fi

    [[ -n "$PIDFILE_PID" ]]
}

write_pidfile() {
    local pid="$1"
    local vault_dir="$2"
    printf '%s\n%s\n' "$pid" "$vault_dir" > "$PIDFILE"
}

resolve_stop_vault_dir() {
    if [[ -n "$PIDFILE_VAULT" ]]; then
        printf '%s\n' "$PIDFILE_VAULT"
        return 0
    fi

    resolve_vault_path 2>/dev/null || true
}

clear_status_state() {
    mkdir -p "$STATUS_DIR"
    rm -f "${STATUS_DIR}"/active-*
}

close_open_tickets() {
    local vault_dir="$1"
    [[ -n "$vault_dir" && -d "$vault_dir" ]] || return 0
    [[ -n "$TK_BIN" ]] || return 0

    local ticket_ids ticket_id
    ticket_ids=$(
        TICKETS_DIR="${vault_dir}/.tickets" "$TK_BIN" list --status=open --tags=troothfairy 2>/dev/null \
        | awk '{print $1}' \
        | grep -E '^[a-zA-Z0-9_-]+$' \
        || true
    )

    [[ -n "$ticket_ids" ]] || return 0

    while IFS= read -r ticket_id; do
        [[ -n "$ticket_id" ]] || continue
        TICKETS_DIR="${vault_dir}/.tickets" "$TK_BIN" add-note "$ticket_id" "Auto-closed: watcher stopped before the job completed" >/dev/null 2>&1 || true
        TICKETS_DIR="${vault_dir}/.tickets" "$TK_BIN" close "$ticket_id" >/dev/null 2>&1 || true
    done <<< "$ticket_ids"
}

# ---------------------------------------------------------------------------
# Preflight: fswatch must be installed
# ---------------------------------------------------------------------------
check_fswatch() {
    if [[ -z "$FSWATCH_BIN" ]]; then
        die "fswatch is not installed. Install it with: brew install fswatch"
    fi
}

# ---------------------------------------------------------------------------
# is_running <pid>
# Returns 0 if a process with that PID exists, 1 otherwise.
# ---------------------------------------------------------------------------
is_running() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

stop_process_group() {
    local pid="$1"

    kill -TERM -- "-${pid}" 2>/dev/null || kill "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# cmd_start [vault_dir]
# ---------------------------------------------------------------------------
cmd_start() {
    check_fswatch

    local vault_dir="${1:-./orb-vault}"
    # Resolve to an absolute path so the pidfile record is unambiguous
    vault_dir="$(cd "$vault_dir" 2>/dev/null && pwd)" \
        || die "vault directory not found: ${1:-./orb-vault}"

    if [[ ! -f "$DISPATCHER" ]]; then
        die "dispatcher not found: $DISPATCHER"
    fi

    # Warn if already running
    if [[ -f "$PIDFILE" ]]; then
        local existing_pid
        read_pidfile || true
        existing_pid="$PIDFILE_PID"
        if is_running "$existing_pid"; then
            echo "watch: watcher is already running (PID ${existing_pid})." >&2
            exit 1
        else
            echo "watch: stale pidfile found (PID ${existing_pid} is dead); removing." >&2
            rm -f "$PIDFILE"
        fi
    fi

    # Launch fswatch in the background.
    #
    # Flags:
    #   --one-per-batch   emit one event per batch (debounces rapid saves)
    #   -r                recursive
    #   -e '\.obsidian'   exclude .obsidian directory
    #   -i '\.md$'        include only .md files  (fswatch -e '' first to
    #                     exclude everything, then -i to re-include .md)
    #
    # Note: fswatch's include/exclude ordering is: exclusions are applied first,
    # then inclusions override them. We exclude everything with -e '.*' and then
    # include \.md$ to get only Markdown files.
    perl -e '
        use strict;
        use warnings;
        setpgrp(0, 0) or die "setpgrp failed: $!";
        exec @ARGV or die "exec failed: $!";
    ' \
        bash -c '
            "$2" \
                --latency 0.1 \
                --one-per-batch \
                -r \
                -e '\''.*'\'' \
                -i '\''\.md$'\'' \
                -e '\''\.obsidian'\'' \
                -e '\''\.tickets'\'' \
                "$1" \
                | while read -r _event; do
                    "$0" "$1" </dev/null
                done
        ' \
        "$DISPATCHER" \
        "$vault_dir" \
        "$FSWATCH_BIN" </dev/null >/dev/null 2>&1 &

    local watch_pid=$!
    disown "$watch_pid" 2>/dev/null || true
    write_pidfile "$watch_pid" "$vault_dir"
    echo -e "${GREEN}watch${NC}: started (PID ${watch_pid}), monitoring ${vault_dir}"
}

# ---------------------------------------------------------------------------
# cmd_stop
# ---------------------------------------------------------------------------
cmd_stop() {
    local pid="" vault_dir="" had_pidfile=false
    if read_pidfile; then
        had_pidfile=true
        pid="$PIDFILE_PID"
        vault_dir="$(resolve_stop_vault_dir)"
    fi

    if [[ -n "$pid" ]] && is_running "$pid"; then
        stop_process_group "$pid"
        # Give the process a moment to die, then confirm
        local retries=5
        while is_running "$pid" && [[ $retries -gt 0 ]]; do
            sleep 0.2
            retries=$((retries - 1))
        done
        if is_running "$pid"; then
            echo -e "${YELLOW}watch${NC}: PID ${pid} did not stop cleanly; sending SIGKILL." >&2
            kill -KILL -- "-${pid}" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true
        fi
        echo -e "${GREEN}watch${NC}: stopped (PID ${pid})."
    else
        if $had_pidfile && [[ -n "$pid" ]]; then
            echo "watch: process ${pid} was already dead."
        else
            echo "watch: no pidfile found — watcher is not running (or was never started)."
        fi
    fi

    clear_status_state
    close_open_tickets "$vault_dir"
    rm -f "$PIDFILE"
    echo "watch: pidfile removed."
}

# ---------------------------------------------------------------------------
# cmd_status
# ---------------------------------------------------------------------------
cmd_status() {
    if ! read_pidfile; then
        echo "watch: not running (no pidfile)."
        exit 1
    fi

    local pid
    pid="$PIDFILE_PID"

    if is_running "$pid"; then
        echo -e "${GREEN}watch${NC}: running (PID ${pid})."
        exit 0
    else
        echo -e "${YELLOW}watch${NC}: pidfile exists but process ${pid} is not running (stale)."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
usage() {
    echo "Usage: $(basename "$0") {start [vault_dir] | stop | status}"
    echo ""
    echo "  start [vault_dir]   Start the fswatch daemon (default vault: ./orb-vault)"
    echo "  stop                Stop the fswatch daemon"
    echo "  status              Check whether the daemon is running"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

case "$1" in
    start)
        shift
        cmd_start "${1:-}"
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    *)
        usage
        ;;
esac
