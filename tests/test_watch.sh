#!/usr/bin/env bash
# test_watch.sh — Integration tests for scripts/watch.sh
#
# Tests start/stop/status lifecycle of the fswatch daemon manager.
#
# Exit codes: 0 = all tests passed, 1 = at least one test failed.
#
# Note: Tests are skipped (exit 0) when fswatch is not installed.

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCH="${SCRIPT_DIR}/../scripts/watch.sh"

# Override the pidfile location so tests never touch /tmp/troothfairy-watch.pid
export PIDFILE="/tmp/troothfairy-watch-test-$$.pid"

# ---------------------------------------------------------------------------
# Skip if fswatch is not installed
# ---------------------------------------------------------------------------
if ! command -v fswatch >/dev/null 2>&1; then
    echo "SKIP: fswatch is not installed — skipping test_watch.sh"
    exit 0
fi

# ---------------------------------------------------------------------------
# Colours / helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "${GREEN}PASS${NC}: $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc — expected='$expected' actual='$actual'"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc — expected to contain: '$needle'"
        echo "  actual output:"
        echo "$haystack" | head -20 | sed 's/^/    /'
    fi
}

# ---------------------------------------------------------------------------
# Temp directory + cleanup
# ---------------------------------------------------------------------------
TMPDIR_ROOT=$(mktemp -d)
VAULT_DIR="${TMPDIR_ROOT}/vault"
mkdir -p "$VAULT_DIR"
FAKE_BIN="${TMPDIR_ROOT}/bin"
mkdir -p "$FAKE_BIN"
STATUS_DIR_TEST="${TMPDIR_ROOT}/status"
mkdir -p "$STATUS_DIR_TEST"
TK_LOG="${TMPDIR_ROOT}/tk.log"
TK_LIST_FILE="${TMPDIR_ROOT}/ticket_list.txt"

export STATUS_DIR="$STATUS_DIR_TEST"
export TK_LOG
export TK_LIST_FILE

# Create a minimal .md file so the vault looks real
cat > "${VAULT_DIR}/note.md" << 'EOF'
# Test note
Just a placeholder so fswatch has a real directory to watch.
EOF

cat > "${FAKE_BIN}/tk" << 'EOF'
#!/usr/bin/env bash
printf '<<TK-CALL>> %s\n' "$*" >> "$TK_LOG"

case "$1" in
    list)
        [[ -f "$TK_LIST_FILE" ]] && cat "$TK_LIST_FILE"
        exit 0
        ;;
    close|add-note)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "${FAKE_BIN}/tk"

ORIGINAL_PATH="$PATH"
export PATH="${FAKE_BIN}:${PATH}"

cleanup() {
    # Kill any watcher we might have started
    if [[ -f "$PIDFILE" ]]; then
        local pid
        pid=$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi
    export PATH="$ORIGINAL_PATH"
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Patch watch.sh to use our test PIDFILE.
#
# watch.sh reads PIDFILE from the environment when the variable is exported,
# but the script hard-codes the path. We create a thin wrapper that overrides
# the variable by rewriting the line in a copy of the script.
# ---------------------------------------------------------------------------

# Make a patched copy of watch.sh that uses our custom PIDFILE
PATCHED_WATCH="${TMPDIR_ROOT}/watch.sh"
sed "s|PIDFILE=\"/tmp/troothfairy-watch.pid\"|PIDFILE=\"${PIDFILE}\"|" \
    "$WATCH" > "$PATCHED_WATCH"
chmod +x "$PATCHED_WATCH"

# Also stub dispatcher.sh with a no-op so fswatch | dispatcher doesn't fail
FAKE_DISPATCHER="${TMPDIR_ROOT}/scripts/dispatcher.sh"
mkdir -p "${TMPDIR_ROOT}/scripts"
cat > "$FAKE_DISPATCHER" << 'DISPSTUB'
#!/usr/bin/env bash
# Stub dispatcher: consume stdin and do nothing
cat > /dev/null
exit 0
DISPSTUB
chmod +x "$FAKE_DISPATCHER"

# Patch the DISPATCHER path in the watch script copy to point at our stub
sed -i.bak "s|DISPATCHER=\"\${SCRIPT_DIR}/dispatcher.sh\"|DISPATCHER=\"${FAKE_DISPATCHER}\"|" \
    "$PATCHED_WATCH"

# ---------------------------------------------------------------------------
# Helper: is_running <pid>
# ---------------------------------------------------------------------------
is_running() {
    kill -0 "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Test 1: start — pidfile is created and process is alive
# ---------------------------------------------------------------------------
echo "--- Test: start"

START_OUTPUT=$("$PATCHED_WATCH" start "$VAULT_DIR" 2>&1)
START_EXIT=$?

assert_eq "start exits with code 0" "0" "$START_EXIT"

if [[ -f "$PIDFILE" ]]; then
    pass "pidfile created after start"
else
    fail "pidfile not found after start"
fi

STARTED_PID=""
if [[ -f "$PIDFILE" ]]; then
    STARTED_PID=$(sed -n '1p' "$PIDFILE")
fi

if [[ -n "$STARTED_PID" ]] && is_running "$STARTED_PID"; then
    pass "watcher process is alive (PID $STARTED_PID)"
else
    fail "watcher process is not running after start (PID='$STARTED_PID')"
fi

PIDFILE_VAULT=""
if [[ -f "$PIDFILE" ]]; then
    PIDFILE_VAULT=$(sed -n '2p' "$PIDFILE")
fi
assert_eq "pidfile stores watched vault path" "$VAULT_DIR" "$PIDFILE_VAULT"

assert_contains "start prints PID confirmation" "started" "$START_OUTPUT"

# ---------------------------------------------------------------------------
# Test 2: start again while already running — should refuse and exit non-zero
# ---------------------------------------------------------------------------
echo "--- Test: start when already running"

START_AGAIN_OUTPUT=$("$PATCHED_WATCH" start "$VAULT_DIR" 2>&1)
START_AGAIN_EXIT=$?

assert_eq "second start exits non-zero" "1" "$START_AGAIN_EXIT"
assert_contains "second start prints already-running message" "already running" "$START_AGAIN_OUTPUT"

# ---------------------------------------------------------------------------
# Test 3: status — reports running
# ---------------------------------------------------------------------------
echo "--- Test: status (running)"

STATUS_OUTPUT=$("$PATCHED_WATCH" status 2>&1)
STATUS_EXIT=$?

assert_eq "status exits 0 when running" "0" "$STATUS_EXIT"
assert_contains "status reports running" "running" "$STATUS_OUTPUT"

# ---------------------------------------------------------------------------
# Test 4: stop — process killed, pidfile removed
# ---------------------------------------------------------------------------
echo "--- Test: stop"

STOP_OUTPUT=$("$PATCHED_WATCH" stop 2>&1)
STOP_EXIT=$?

assert_eq "stop exits with code 0" "0" "$STOP_EXIT"
assert_contains "stop prints stopped confirmation" "stopped" "$STOP_OUTPUT"

if [[ ! -f "$PIDFILE" ]]; then
    pass "pidfile removed after stop"
else
    fail "pidfile still present after stop"
fi

if [[ -n "$STARTED_PID" ]] && ! is_running "$STARTED_PID"; then
    pass "watcher process is dead after stop (PID $STARTED_PID)"
else
    fail "watcher process still running after stop (PID='$STARTED_PID')"
fi

# ---------------------------------------------------------------------------
# Test 5: status — reports not running after stop
# ---------------------------------------------------------------------------
echo "--- Test: status (not running)"

STATUS2_OUTPUT=$("$PATCHED_WATCH" status 2>&1)
STATUS2_EXIT=$?

assert_eq "status exits non-zero when no pidfile" "1" "$STATUS2_EXIT"
assert_contains "status reports not running" "not running" "$STATUS2_OUTPUT"

# ---------------------------------------------------------------------------
# Test 6: stop when not running — graceful (no pidfile)
# ---------------------------------------------------------------------------
echo "--- Test: stop when not running (no pidfile)"

STOP2_OUTPUT=$("$PATCHED_WATCH" stop 2>&1)
STOP2_EXIT=$?

assert_eq "stop with no pidfile exits 0" "0" "$STOP2_EXIT"
assert_contains "stop with no pidfile prints graceful message" "not running" "$STOP2_OUTPUT"

# ---------------------------------------------------------------------------
# Test 7: stop with stale pidfile (process already dead)
# ---------------------------------------------------------------------------
echo "--- Test: stop with stale pidfile"

# Write a PID that definitely doesn't exist
echo "99999999" > "$PIDFILE"

STOP3_OUTPUT=$("$PATCHED_WATCH" stop 2>&1)
STOP3_EXIT=$?

assert_eq "stop with dead PID exits 0" "0" "$STOP3_EXIT"
assert_contains "stop with dead PID notes process was already dead" "already dead" "$STOP3_OUTPUT"

if [[ ! -f "$PIDFILE" ]]; then
    pass "stale pidfile removed after stop"
else
    fail "stale pidfile still present after stop"
fi

# ---------------------------------------------------------------------------
# Test 8: no arguments — prints usage and exits non-zero
# ---------------------------------------------------------------------------
echo "--- Test: no arguments"

USAGE_OUTPUT=$("$PATCHED_WATCH" 2>&1 || true)
USAGE_EXIT=$("$PATCHED_WATCH" 2>/dev/null; echo $?) || true
# Re-run properly capturing exit code
"$PATCHED_WATCH" > /dev/null 2>&1; USAGE_EXIT=$?

assert_eq "no-args exits non-zero" "1" "$USAGE_EXIT"
assert_contains "no-args prints usage" "Usage" "$USAGE_OUTPUT"

# ---------------------------------------------------------------------------
# Test 9: stop kills the entire watcher pipeline, not just the parent shell
# ---------------------------------------------------------------------------
echo "--- Test: stop kills watcher process group"

FAKE_LOG="${TMPDIR_ROOT}/dispatcher.log"
cat > "${FAKE_BIN}/fswatch" << 'EOF'
#!/usr/bin/env bash
while true; do
    printf '%s\n' "event"
    sleep 0.1
done
EOF
chmod +x "${FAKE_BIN}/fswatch"

cat > "$FAKE_DISPATCHER" << 'DISPSTUB'
#!/usr/bin/env bash
echo "dispatch" >> "$FAKE_LOG"
exit 0
DISPSTUB
chmod +x "$FAKE_DISPATCHER"

ORIGINAL_PATH="$PATH"
export PATH="${FAKE_BIN}:${PATH}"
export FAKE_LOG
: > "$FAKE_LOG"

GROUP_START_OUTPUT=$("$PATCHED_WATCH" start "$VAULT_DIR" 2>&1)
GROUP_START_EXIT=$?
assert_eq "group-regression start exits 0" "0" "$GROUP_START_EXIT"

sleep 0.4
dispatch_count_before_stop=$(wc -l < "$FAKE_LOG" 2>/dev/null || echo 0)
STOP_GROUP_OUTPUT=$("$PATCHED_WATCH" stop 2>&1)
STOP_GROUP_EXIT=$?
sleep 0.4
dispatch_count_after_stop=$(wc -l < "$FAKE_LOG" 2>/dev/null || echo 0)

assert_eq "group-regression stop exits 0" "0" "$STOP_GROUP_EXIT"
assert_contains "group-regression stop prints stopped confirmation" "stopped" "$STOP_GROUP_OUTPUT"
assert_eq "dispatcher count stops increasing after stop" "$dispatch_count_before_stop" "$dispatch_count_after_stop"

echo "--- Test: stop clears active jobs and closes open tickets"

: > "$TK_LOG"
printf '%s\n' "ticket-stop-1" > "$TK_LIST_FILE"
printf '%s\n' "ticket-stop-2" >> "$TK_LIST_FILE"
mkdir -p "$STATUS_DIR"
printf '%s\n' "active job" > "${STATUS_DIR}/active-ticket-stop-1"
printf '%s\n' "active job" > "${STATUS_DIR}/active-ticket-stop-2"

CLEAN_START_OUTPUT=$("$PATCHED_WATCH" start "$VAULT_DIR" 2>&1)
CLEAN_START_EXIT=$?
assert_eq "cleanup suite start exits 0" "0" "$CLEAN_START_EXIT"

CLEAN_STOP_OUTPUT=$("$PATCHED_WATCH" stop 2>&1)
CLEAN_STOP_EXIT=$?
assert_eq "cleanup suite stop exits 0" "0" "$CLEAN_STOP_EXIT"
assert_contains "cleanup suite stop prints pidfile removed" "pidfile removed" "$CLEAN_STOP_OUTPUT"

if compgen -G "${STATUS_DIR}/active-*" > /dev/null; then
    fail "active status files still exist after stop cleanup"
else
    pass "active status files cleared after stop cleanup"
fi

TK_CALLS=$(cat "$TK_LOG" 2>/dev/null || true)
assert_contains "stop queries open troothfairy tickets" "list --status=open --tags=troothfairy" "$TK_CALLS"
assert_contains "stop adds note to first ticket" "add-note ticket-stop-1 Auto-closed: watcher stopped before the job completed" "$TK_CALLS"
assert_contains "stop closes first ticket" "close ticket-stop-1" "$TK_CALLS"
assert_contains "stop closes second ticket" "close ticket-stop-2" "$TK_CALLS"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
