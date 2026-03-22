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
PIDFILE_VAULTS=()

read_pidfile() {
    PIDFILE_PID=""
    PIDFILE_VAULT=""
    PIDFILE_VAULTS=()
    [[ -f "$PIDFILE" ]] || return 1

    local pid_line vault_line extra_vault
    pid_line=$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)
    vault_line=$(sed -n '2p' "$PIDFILE" 2>/dev/null || true)

    if [[ -n "$pid_line" && "$pid_line" == *$'\t'* ]]; then
        PIDFILE_PID="${pid_line%%$'\t'*}"
        PIDFILE_VAULT="${pid_line#*$'\t'}"
    else
        PIDFILE_PID="$pid_line"
        PIDFILE_VAULT="$vault_line"
    fi

    if [[ -n "$PIDFILE_VAULT" ]]; then
        PIDFILE_VAULTS+=("$PIDFILE_VAULT")
    fi
    while IFS= read -r extra_vault; do
        [[ -n "$extra_vault" ]] || continue
        PIDFILE_VAULTS+=("$extra_vault")
    done < <(sed -n '3,$p' "$PIDFILE" 2>/dev/null || true)

    [[ -n "$PIDFILE_PID" ]]
}

write_pidfile() {
    local pid="$1"
    shift
    {
        printf '%s\n' "$pid"
        while [[ $# -gt 0 ]]; do
            printf '%s\n' "$1"
            shift
        done
    } > "$PIDFILE"
}

resolve_stop_vault_dirs() {
    if [[ ${#PIDFILE_VAULTS[@]} -gt 0 ]]; then
        printf '%s\n' "${PIDFILE_VAULTS[@]}"
        return 0
    fi

    resolve_vault_paths 2>/dev/null || true
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
# cmd_start [vault_dir ...]
# ---------------------------------------------------------------------------
cmd_start() {
    check_fswatch

    local vault_dirs=()
    local requested_vault resolved_vault
    if [[ $# -gt 0 ]]; then
        for requested_vault in "$@"; do
            resolved_vault="$(cd "$requested_vault" 2>/dev/null && pwd)" \
                || die "vault directory not found: ${requested_vault}"
            vault_dirs+=("$resolved_vault")
        done
    else
        while IFS= read -r resolved_vault; do
            [[ -n "$resolved_vault" ]] || continue
            vault_dirs+=("$resolved_vault")
        done < <(resolve_vault_paths 2>/dev/null || true)
    fi

    if [[ ${#vault_dirs[@]} -eq 0 ]]; then
        die "no vault directories configured. Set vault_path or vaults in config.yaml, or pass vault directories explicitly."
    fi

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
            dispatcher="$1"
            fswatch_bin="$2"
            shift 2
            "$fswatch_bin" \
                --latency 0.1 \
                -r \
                -e '\''.*'\'' \
                -i '\''\.md$'\'' \
                -e '\''\.obsidian'\'' \
                -e '\''\.tickets'\'' \
                "$@" \
                | while IFS= read -r event_path; do
                    dispatch_vault=""
                    for vault_dir in "$@"; do
                        case "$event_path" in
                            "$vault_dir"|"$vault_dir"/*)
                                dispatch_vault="$vault_dir"
                                break
                                ;;
                        esac
                    done
                    if [[ -n "$dispatch_vault" ]]; then
                        "$dispatcher" "$dispatch_vault" </dev/null
                    fi
                done
        ' \
        _ \
        "$DISPATCHER" \
        "$FSWATCH_BIN" \
        "${vault_dirs[@]}" </dev/null >/dev/null 2>&1 &

    local watch_pid=$!
    disown "$watch_pid" 2>/dev/null || true
    write_pidfile "$watch_pid" "${vault_dirs[@]}"
    echo -e "${GREEN}watch${NC}: started (PID ${watch_pid}), monitoring ${#vault_dirs[@]} vault(s)."
}

# ---------------------------------------------------------------------------
# cmd_stop
# ---------------------------------------------------------------------------
cmd_stop() {
    local pid="" had_pidfile=false vault_dir
    local vault_dirs_to_close=()
    if read_pidfile; then
        had_pidfile=true
        pid="$PIDFILE_PID"
        while IFS= read -r vault_dir; do
            [[ -n "$vault_dir" ]] || continue
            vault_dirs_to_close+=("$vault_dir")
        done < <(resolve_stop_vault_dirs)
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
    if [[ ${#vault_dirs_to_close[@]} -gt 0 ]]; then
        for vault_dir in "${vault_dirs_to_close[@]}"; do
            close_open_tickets "$vault_dir"
        done
    fi
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
    echo "Usage: $(basename "$0") {start [vault_dir ...] | stop | status}"
    echo ""
    echo "  start [vault_dir ...]   Start the fswatch daemon (default: configured vault_path/vaults)"
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
        cmd_start "$@"
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
