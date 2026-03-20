#!/usr/bin/env bash
# test_dispatcher.sh — Integration tests for scripts/dispatcher.sh
#
# Creates a temporary vault with known tag/block structures, stubs `tk`,
# runs the dispatcher, and verifies the expected behaviour.
#
# Exit codes: 0 = all tests passed, 1 = at least one test failed.

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${SCRIPT_DIR}/../scripts/dispatcher.sh"

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
        echo "$haystack" | head -40 | sed 's/^/    /'
    fi
}

# ---------------------------------------------------------------------------
# Temp directory + cleanup
# ---------------------------------------------------------------------------
TMPDIR_ROOT=$(mktemp -d)
VAULT_DIR="${TMPDIR_ROOT}/vault"
TK_LOG="${TMPDIR_ROOT}/tk_calls.log"
FAKE_BIN="${TMPDIR_ROOT}/bin"
mkdir -p "$VAULT_DIR" "$FAKE_BIN"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
    rm -f /tmp/TROOTHLOCK
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Stub `tk` — records all invocations to TK_LOG
# ---------------------------------------------------------------------------
cat > "${FAKE_BIN}/tk" << 'TKSTUB'
#!/usr/bin/env bash
# Fake tk: record each invocation with a delimiter, then all args
printf '<<CALL>> %s\n' "$*" >> "$TK_LOG"
exit 0
TKSTUB
chmod +x "${FAKE_BIN}/tk"

# Put fake bin first on PATH for this session
export PATH="${FAKE_BIN}:${PATH}"
export TK_LOG   # dispatcher inherits this env var (log path is used by stub)

# Stub out the orchestrator so the dispatcher doesn't try to run it
export ORCHESTRATOR=/usr/bin/true

# ---------------------------------------------------------------------------
# Build sample vault files
# ---------------------------------------------------------------------------

# --- file_a.md ---
# Contains:
#   • A non-bullet line tagged #ƒ                        (line 1)
#   • A bullet tagged #∆ with two nested children        (lines 5-7)
#   • A second top-level bullet tagged #© with one child (lines 9-10)
cat > "${VAULT_DIR}/file_a.md" << 'EOF'
#ƒ This is a plain instruction line — not a bullet.

Some normal prose that should be ignored.

- #∆ Top-level bullet with evaluate tag
	- Child bullet one
	- Child bullet two
- Untagged sibling bullet (ends the previous block)
- #© Validate this bullet
	- Nested child under validate bullet
- Another untagged bullet (ends the © block)
EOF

# --- file_b.md ---
# Contains:
#   • A #∑ tag on a bullet with deeply nested children   (lines 1-4)
#   • A #ƒ tag on a non-bullet                           (line 6)
cat > "${VAULT_DIR}/file_b.md" << 'EOF'
- #∑ Evaluate with full context
	- Level 2 child
		- Level 3 grandchild
	- Level 2 sibling child
#ƒ Explicit instruction on a non-bullet line
EOF

# --- file_c.md ---
# Contains NO open tags — dispatcher should skip this file entirely.
cat > "${VAULT_DIR}/file_c.md" << 'EOF'
# A clean note

This file has no Troothfairy tags and should never generate a ticket.

- Just a normal bullet
EOF

# ---------------------------------------------------------------------------
# Remove stale lock before running (in case a previous failed run left one)
# ---------------------------------------------------------------------------
rm -f /tmp/TROOTHLOCK

# ---------------------------------------------------------------------------
# Run dispatcher
# ---------------------------------------------------------------------------
DISPATCHER_OUTPUT=$("$DISPATCHER" "$VAULT_DIR" 2>&1)
DISPATCHER_EXIT=$?

# ---------------------------------------------------------------------------
# Test 1: dispatcher exits cleanly
# ---------------------------------------------------------------------------
assert_eq "dispatcher exits with code 0" "0" "$DISPATCHER_EXIT"

# ---------------------------------------------------------------------------
# Test 2: lock file is removed after run
# ---------------------------------------------------------------------------
if [[ ! -f /tmp/TROOTHLOCK ]]; then
    pass "TROOTHLOCK removed after dispatcher exits"
else
    fail "TROOTHLOCK still present after dispatcher exits"
fi

# ---------------------------------------------------------------------------
# Test 3: correct number of tk tickets created
# Expected: 5 tickets (one per tagged block across file_a.md and file_b.md)
# ---------------------------------------------------------------------------
if [[ -f "$TK_LOG" ]]; then
    ticket_count=$(grep -c '<<CALL>>' "$TK_LOG" || true)
else
    ticket_count=0
fi
assert_eq "5 tickets created (one per tagged block)" "5" "$ticket_count"

# ---------------------------------------------------------------------------
# Test 4: ticket created for file_a.md
# ---------------------------------------------------------------------------
if [[ -f "$TK_LOG" ]]; then
    FILE_A_TICKET=$(grep "file_a.md" "$TK_LOG" || true)
else
    FILE_A_TICKET=""
fi
assert_contains "tk called with file_a.md title" "Troothfairy: file_a.md" "$FILE_A_TICKET"

# ---------------------------------------------------------------------------
# Test 5: ticket created for file_b.md
# ---------------------------------------------------------------------------
if [[ -f "$TK_LOG" ]]; then
    FILE_B_TICKET=$(grep "file_b.md" "$TK_LOG" || true)
else
    FILE_B_TICKET=""
fi
assert_contains "tk called with file_b.md title" "Troothfairy: file_b.md" "$FILE_B_TICKET"

# ---------------------------------------------------------------------------
# Test 6: file_c.md does NOT get a ticket
# ---------------------------------------------------------------------------
if [[ -f "$TK_LOG" ]]; then
    FILE_C_TICKET=$(grep "file_c.md" "$TK_LOG" || true)
else
    FILE_C_TICKET=""
fi
if [[ -z "$FILE_C_TICKET" ]]; then
    pass "no ticket created for untagged file_c.md"
else
    fail "unexpected ticket created for file_c.md"
fi

# ---------------------------------------------------------------------------
# Test 7: all four tag types represented across the two tickets
# ---------------------------------------------------------------------------
if [[ -f "$TK_LOG" ]]; then
    ALL_CALLS=$(cat "$TK_LOG")
else
    ALL_CALLS=""
fi
assert_contains "tag ƒ appears in tickets"  "ƒ" "$ALL_CALLS"
assert_contains "tag ∆ appears in tickets"  "∆" "$ALL_CALLS"
assert_contains "tag ∑ appears in tickets"  "∑" "$ALL_CALLS"
assert_contains "tag © appears in tickets"  "©" "$ALL_CALLS"

# ---------------------------------------------------------------------------
# Test 8: block extraction — nested children of #∆ bullet are in description
# The block for the #∆ line in file_a.md should include "Child bullet one"
# and "Child bullet two" but NOT the untagged sibling or © bullet.
# ---------------------------------------------------------------------------
assert_contains "#∆ block contains 'Child bullet one'"  "Child bullet one"  "$ALL_CALLS"
assert_contains "#∆ block contains 'Child bullet two'"  "Child bullet two"  "$ALL_CALLS"

# ---------------------------------------------------------------------------
# Test 9: block extraction — #© bullet captures its nested child
# ---------------------------------------------------------------------------
assert_contains "#© block captures nested child" "Nested child under validate bullet" "$ALL_CALLS"

# ---------------------------------------------------------------------------
# Test 10: block extraction — #∑ bullet captures all three nested lines
# ---------------------------------------------------------------------------
assert_contains "#∑ block contains 'Level 2 child'"          "Level 2 child"          "$ALL_CALLS"
assert_contains "#∑ block contains 'Level 3 grandchild'"     "Level 3 grandchild"     "$ALL_CALLS"
assert_contains "#∑ block contains 'Level 2 sibling child'"  "Level 2 sibling child"  "$ALL_CALLS"

# ---------------------------------------------------------------------------
# Test 11: block extraction — non-bullet #ƒ line is a single line only
# It must NOT include the blank line or prose below it from file_a.md.
# ---------------------------------------------------------------------------
# The plain instruction text is unique enough to look for directly.
assert_contains "#ƒ plain instruction text captured" "plain instruction line" "$ALL_CALLS"

# ---------------------------------------------------------------------------
# Test 12: structured payload includes route and line metadata
# ---------------------------------------------------------------------------
assert_contains "payload includes api-search route" '"route": "api-search"' "$ALL_CALLS"
assert_contains "payload includes local line metadata" '"line_number": 1' "$ALL_CALLS"
assert_contains "payload includes block content field" '"block_content"' "$ALL_CALLS"

# ---------------------------------------------------------------------------
# Test 13: TROOTHLOCK prevents re-entry
# Create the lock manually, run again, and confirm no new tickets appear.
# ---------------------------------------------------------------------------
touch /tmp/TROOTHLOCK
SECOND_RUN_OUTPUT=$("$DISPATCHER" "$VAULT_DIR" 2>&1)
SECOND_RUN_EXIT=$?
rm -f /tmp/TROOTHLOCK   # tidy up (dispatcher won't since it exited early)

assert_eq "second run with lock exits 0" "0" "$SECOND_RUN_EXIT"

# Ticket count must still be 5 (no new calls added)
if [[ -f "$TK_LOG" ]]; then
    ticket_count_after=$(grep -c '<<CALL>>' "$TK_LOG" || true)
else
    ticket_count_after=0
fi
assert_eq "no additional tickets created when locked" "5" "$ticket_count_after"

# ---------------------------------------------------------------------------
# Test 14: dispatcher summary output contains ticket count
# ---------------------------------------------------------------------------
assert_contains "dispatcher prints ticket count summary" "created 5 ticket" "$DISPATCHER_OUTPUT"

# ---------------------------------------------------------------------------
# Test 14: tags flag included in tk call
# ---------------------------------------------------------------------------
assert_contains "tk call includes --tags troothfairy,auto" "--tags troothfairy,auto" "$ALL_CALLS"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
