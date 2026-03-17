#!/usr/bin/env bash
# test_orchestrator.sh — Integration tests for scripts/orchestrator.sh
#
# Stubs `tk` and `claude`, creates mock tickets with known descriptions,
# runs the orchestrator, and verifies correct behaviour including:
#   - Correct number of subagents spawned
#   - Correct prompts passed (tag info, sourcing guide content, etc.)
#   - Tickets closed on success
#   - Failure case: ticket stays open with error note
#
# Exit codes: 0 = all tests passed, 1 = at least one test failed.

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORCHESTRATOR="${REPO_ROOT}/scripts/orchestrator.sh"

# ---------------------------------------------------------------------------
# Colours / helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASS=0
FAIL=0

pass() { printf "${GREEN}PASS${NC}: %s\n" "$*"; PASS=$((PASS + 1)); }
fail() { printf "${RED}FAIL${NC}: %s\n" "$*"; FAIL=$((FAIL + 1)); }

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
        printf '  actual output (first 20 lines):\n'
        printf '%s\n' "$haystack" | head -20 | sed 's/^/    /'
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc — expected NOT to contain: '$needle'"
    fi
}

# ---------------------------------------------------------------------------
# Temp directory + cleanup
# ---------------------------------------------------------------------------
TMPDIR_ROOT=$(mktemp -d)
VAULT_DIR="${TMPDIR_ROOT}/vault"
FAKE_BIN="${TMPDIR_ROOT}/bin"
TK_LOG="${TMPDIR_ROOT}/tk_calls.log"
CLAUDE_LOG="${TMPDIR_ROOT}/claude_calls.log"
# CLAUDE_FAIL_TICKET is set below after tickets are defined
CLAUDE_FAIL_TICKET=""

mkdir -p "$VAULT_DIR" "$FAKE_BIN"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

export TK_LOG
export CLAUDE_LOG
export STATUS_DIR="${TMPDIR_ROOT}/status"
mkdir -p "$STATUS_DIR"
export CLAUDE_FAIL_TICKET
export VAULT_DIR

# ---------------------------------------------------------------------------
# Build mock vault files
# ---------------------------------------------------------------------------

# file_a.md — has #∆ and #© tags
cat > "${VAULT_DIR}/file_a.md" << 'EOF'
- #∆ Transformer models use self-attention.
	- Child context bullet
- #© The speed of light is approximately 3e8 m/s.
EOF

# file_b.md — has #∑ tag (needs full file context) and #ƒ tag
cat > "${VAULT_DIR}/file_b.md" << 'EOF'
- #∑ Evaluate this with full context
	- Related sub-bullet
#ƒ Summarize the three laws of thermodynamics.
EOF

# ---------------------------------------------------------------------------
# Create mock ticket data
# The orchestrator calls `tk list --status=open --tags=troothfairy`
# then `tk show <id>` for each ticket.
#
# We store per-ticket show output in files the stub can read.
# ---------------------------------------------------------------------------
TICKET_DATA_DIR="${TMPDIR_ROOT}/ticket_data"
mkdir -p "$TICKET_DATA_DIR"

TICKET_A="troothfairy-t001"
TICKET_B="troothfairy-t002"

# Ticket A describes file_a.md with #∆ and #©
cat > "${TICKET_DATA_DIR}/${TICKET_A}" << EOF
Troothfairy: file_a.md

--- Tag #∆ (evaluate and enrich) at line 1 ---
- #∆ Transformer models use self-attention.
	- Child context bullet

--- Tag #© (validate/check) at line 3 ---
- #© The speed of light is approximately 3e8 m/s.

EOF

# Ticket B describes file_b.md with #∑ and #ƒ
cat > "${TICKET_DATA_DIR}/${TICKET_B}" << EOF
Troothfairy: file_b.md

--- Tag #∑ (evaluate with full file context) at line 1 ---
- #∑ Evaluate this with full context
	- Related sub-bullet

--- Tag #ƒ (explicit instruction) at line 3 ---
#ƒ Summarize the three laws of thermodynamics.

EOF

export TICKET_DATA_DIR
export TICKET_A
export TICKET_B

# ---------------------------------------------------------------------------
# Stub: `tk`
#
# Handles:
#   tk list --status=open --tags=troothfairy  -> prints two ticket IDs
#   tk show <id>                               -> prints mock ticket body
#   tk close <id>                              -> records call, exits 0
#   tk add-note <id> <note>                    -> records call, exits 0
#
# All calls are logged to TK_LOG.
# ---------------------------------------------------------------------------
cat > "${FAKE_BIN}/tk" << 'TKSTUB'
#!/usr/bin/env bash
printf '<<TK-CALL>> %s\n' "$*" >> "$TK_LOG"

case "$1" in
    list)
        # Return open ticket IDs, one per line
        printf '%s\n' "$TICKET_A"
        printf '%s\n' "$TICKET_B"
        exit 0
        ;;
    show)
        ticket_id="$2"
        show_file="${TICKET_DATA_DIR}/${ticket_id}"
        if [[ -f "$show_file" ]]; then
            cat "$show_file"
            exit 0
        else
            echo "tk stub: unknown ticket: $ticket_id" >&2
            exit 1
        fi
        ;;
    close)
        # Success — just record the call (already logged above)
        exit 0
        ;;
    add-note)
        # Success — record the call (already logged above)
        exit 0
        ;;
    *)
        echo "tk stub: unrecognised command: $1" >&2
        exit 1
        ;;
esac
TKSTUB
chmod +x "${FAKE_BIN}/tk"

# ---------------------------------------------------------------------------
# Stub: `claude`
#
# Records the full invocation (flags + prompt) to CLAUDE_LOG.
# If CLAUDE_FAIL_TICKET is set and the prompt contains the ticket's
# file basename, exits non-zero to simulate a failure.
# ---------------------------------------------------------------------------
cat > "${FAKE_BIN}/claude" << 'CLAUDESTUB'
#!/usr/bin/env bash
# Log all arguments
full_args="$*"

# Detect haiku summarization calls vs main subagent calls
if printf '%s\n' "$full_args" | grep -qF -- '--model haiku'; then
    printf '<<HAIKU-CALL>>\n%s\n<<END-HAIKU-CALL>>\n' "$full_args" >> "$CLAUDE_LOG"
    # Echo back the tag lines with "summarized:" prefix to simulate summarization
    # The prompt contains lines like "#∆ Transformer models use self-attention..."
    printf '%s\n' "$full_args" | grep -E '^#.' | while IFS= read -r tagline; do
        tc=$(printf '%s' "$tagline" | cut -c1-4)  # e.g. "#∆" (unicode = multi-byte)
        printf '%s Summarized task\n' "$tc"
    done
    exit 0
fi

printf '<<CLAUDE-CALL>>\n%s\n<<END-CLAUDE-CALL>>\n' "$full_args" >> "$CLAUDE_LOG"

# Check if we should simulate failure for a specific ticket
if [[ -n "$CLAUDE_FAIL_TICKET" ]]; then
    if printf '%s\n' "$full_args" | grep -qF "$CLAUDE_FAIL_TICKET"; then
        echo "simulated claude failure for $CLAUDE_FAIL_TICKET" >&2
        exit 1
    fi
fi

exit 0
CLAUDESTUB
chmod +x "${FAKE_BIN}/claude"

# Put stubs first on PATH
export PATH="${FAKE_BIN}:${PATH}"

# ---------------------------------------------------------------------------
# ── TEST SUITE 1: Normal run (all subagents succeed) ─────────────────────────
# ---------------------------------------------------------------------------
echo "=== Suite 1: Normal run (all succeed) ==="

ORCH_OUTPUT=$("$ORCHESTRATOR" "$VAULT_DIR" 2>&1)
ORCH_EXIT=$?

# 1. Orchestrator exits cleanly
assert_eq "orchestrator exits with code 0" "0" "$ORCH_EXIT"

# 2. Two claude invocations (one per ticket)
if [[ -f "$CLAUDE_LOG" ]]; then
    claude_call_count=$(grep -c '<<CLAUDE-CALL>>' "$CLAUDE_LOG" || true)
else
    claude_call_count=0
fi
assert_eq "two claude subagents launched (one per ticket)" "2" "$claude_call_count"

# 3. Both tickets are listed via tk list
if [[ -f "$TK_LOG" ]]; then
    TK_ALL=$(cat "$TK_LOG")
else
    TK_ALL=""
fi
assert_contains "tk list called with --status=open" "--status=open" "$TK_ALL"
assert_contains "tk list called with --tags=troothfairy" "--tags=troothfairy" "$TK_ALL"

# 4. tk show called for each ticket
assert_contains "tk show called for ticket A" "show ${TICKET_A}" "$TK_ALL"
assert_contains "tk show called for ticket B" "show ${TICKET_B}" "$TK_ALL"

# 5. Both tickets closed on success
assert_contains "ticket A closed on success" "close ${TICKET_A}" "$TK_ALL"
assert_contains "ticket B closed on success" "close ${TICKET_B}" "$TK_ALL"

# 6. Prompt for file_a.md contains tag entries from ticket A
if [[ -f "$CLAUDE_LOG" ]]; then
    CLAUDE_ALL=$(cat "$CLAUDE_LOG")
else
    CLAUDE_ALL=""
fi
assert_contains "file_a.md path in a claude prompt"     "file_a.md"              "$CLAUDE_ALL"
assert_contains "#∆ tag info in claude prompt"           "∆ (evaluate and enrich)" "$CLAUDE_ALL"
assert_contains "#© tag info in claude prompt"           "© (validate/check)"      "$CLAUDE_ALL"
assert_contains "block content for #∆ in prompt"        "Transformer models"      "$CLAUDE_ALL"
assert_contains "block content for #© in prompt"        "speed of light"          "$CLAUDE_ALL"

# 7. Prompt for file_b.md contains tag entries from ticket B
assert_contains "file_b.md path in a claude prompt"     "file_b.md"                          "$CLAUDE_ALL"
assert_contains "#∑ tag info in claude prompt"           "∑ (evaluate with full file context)" "$CLAUDE_ALL"
assert_contains "#ƒ tag info in claude prompt"           "ƒ (explicit instruction)"             "$CLAUDE_ALL"
assert_contains "block content for #∑ in prompt"        "Evaluate this with full context"     "$CLAUDE_ALL"
assert_contains "block content for #ƒ in prompt"        "laws of thermodynamics"              "$CLAUDE_ALL"

# 8. Full file content injected for #∑ ticket (file_b.md)
assert_contains "#∑ prompt includes full file content" "Related sub-bullet" "$CLAUDE_ALL"

# 9. Sourcing blacklist content injected into system prompt
assert_contains "blacklist domain in system prompt (nymag.com)"     "nymag.com"     "$CLAUDE_ALL"
assert_contains "blacklist domain in system prompt (medium.com)"    "medium.com"    "$CLAUDE_ALL"

# 10. Sourcing whitelist content injected into system prompt
assert_contains "whitelist domain in system prompt (arxiv.org)"     "arxiv.org"     "$CLAUDE_ALL"
assert_contains "whitelist domain in system prompt (github.com)"    "github.com"    "$CLAUDE_ALL"

# 11. System prompt tag instructions present
assert_contains "system prompt contains #∆ instructions" "#∆" "$CLAUDE_ALL"
assert_contains "system prompt contains #ƒ instructions" "#ƒ" "$CLAUDE_ALL"
assert_contains "system prompt contains #Ω format rule"  "#Ω" "$CLAUDE_ALL"
assert_contains "system prompt contains #¡ failure rule" "#¡" "$CLAUDE_ALL"

# 12. --allowedTools flag passed to claude (without Bash by default)
assert_contains "claude called with --allowedTools" "--allowedTools" "$CLAUDE_ALL"
assert_contains "default tools include Edit" "Edit" "$CLAUDE_ALL"
assert_not_contains "default tools exclude Bash" "Bash" "$CLAUDE_ALL"

# 13. Default model is sonnet
assert_contains "default model is sonnet" "--model sonnet" "$CLAUDE_ALL"

# 14. No add-note calls in successful run
# (There should be no "add-note" in the TK log for success-only run)
if printf '%s\n' "$TK_ALL" | grep -qF "add-note"; then
    fail "no add-note calls expected in all-success run"
else
    pass "no add-note calls in all-success run"
fi

echo ""

# ---------------------------------------------------------------------------
# ── TEST SUITE 2: Failure case ────────────────────────────────────────────────
# One subagent fails; its ticket should stay open with an error note.
# The other succeeds and is closed.
# ---------------------------------------------------------------------------
echo "=== Suite 2: One subagent fails ==="

# Reset logs
rm -f "$TK_LOG" "$CLAUDE_LOG"
touch "$TK_LOG" "$CLAUDE_LOG"

# Configure claude stub to fail for file_b.md
export CLAUDE_FAIL_TICKET="file_b.md"

ORCH_FAIL_OUTPUT=$("$ORCHESTRATOR" "$VAULT_DIR" 2>&1)
ORCH_FAIL_EXIT=$?

# Unset so it doesn't bleed into future calls
export CLAUDE_FAIL_TICKET=""

if [[ -f "$TK_LOG" ]]; then
    TK_FAIL=$(cat "$TK_LOG")
else
    TK_FAIL=""
fi

# 14. Orchestrator exits with non-zero when at least one subagent fails
if [[ "$ORCH_FAIL_EXIT" -ne 0 ]]; then
    pass "orchestrator exits non-zero when a subagent fails"
else
    fail "orchestrator should exit non-zero when a subagent fails (got 0)"
fi

# 15. Successful ticket (file_a.md → TICKET_A) is still closed
assert_contains "ticket A still closed when ticket B fails" "close ${TICKET_A}" "$TK_FAIL"

# 16. Failed ticket (file_b.md → TICKET_B) is NOT closed
if printf '%s\n' "$TK_FAIL" | grep -qF "close ${TICKET_B}"; then
    fail "ticket B should NOT be closed after subagent failure"
else
    pass "ticket B not closed after subagent failure"
fi

# 17. Failed ticket gets an add-note call
assert_contains "add-note called for failed ticket B" "add-note ${TICKET_B}" "$TK_FAIL"

# 18. The note mentions failure
ADD_NOTE_LINE=$(printf '%s\n' "$TK_FAIL" | grep "add-note ${TICKET_B}" | head -1)
assert_contains "failure note contains 'Failed'" "Failed" "$ADD_NOTE_LINE"

echo ""

# ---------------------------------------------------------------------------
# ── TEST SUITE 3: No open tickets ────────────────────────────────────────────
# When there are no open troothfairy tickets the orchestrator exits cleanly
# without launching any subagents.
# ---------------------------------------------------------------------------
echo "=== Suite 3: No open tickets ==="

# Replace tk stub with one that returns empty for list
cat > "${FAKE_BIN}/tk" << 'TKSTUB_EMPTY'
#!/usr/bin/env bash
printf '<<TK-CALL>> %s\n' "$*" >> "$TK_LOG"

case "$1" in
    list)
        # No tickets — print nothing
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
TKSTUB_EMPTY
chmod +x "${FAKE_BIN}/tk"

rm -f "$TK_LOG" "$CLAUDE_LOG"
touch "$TK_LOG" "$CLAUDE_LOG"

ORCH_EMPTY_OUTPUT=$("$ORCHESTRATOR" "$VAULT_DIR" 2>&1)
ORCH_EMPTY_EXIT=$?

# 19. Clean exit with no tickets
assert_eq "orchestrator exits 0 with no tickets" "0" "$ORCH_EMPTY_EXIT"

# 20. No claude calls made
if [[ -f "$CLAUDE_LOG" ]]; then
    empty_claude_count=$(grep -c '<<CLAUDE-CALL>>' "$CLAUDE_LOG" 2>/dev/null || true)
else
    empty_claude_count=0
fi
assert_eq "no claude calls when no tickets" "0" "$empty_claude_count"

# 21. Output contains informative message
assert_contains "output mentions no tickets" "no open troothfairy tickets" "$ORCH_EMPTY_OUTPUT"

echo ""

# ---------------------------------------------------------------------------
# ── TEST SUITE 4: Modifier overrides (#bash, #opus) ─────────────────────────
# When tag blocks contain #bash or #opus, the subagent should use those.
# ---------------------------------------------------------------------------
echo "=== Suite 4: Modifier overrides ==="

# Restore the full tk stub
cat > "${FAKE_BIN}/tk" << 'TKSTUB4'
#!/usr/bin/env bash
printf '<<TK-CALL>> %s\n' "$*" >> "$TK_LOG"

case "$1" in
    list)
        printf '%s\n' "$TICKET_A"
        exit 0
        ;;
    show)
        ticket_id="$2"
        show_file="${TICKET_DATA_DIR}/${ticket_id}"
        if [[ -f "$show_file" ]]; then
            cat "$show_file"
            exit 0
        fi
        exit 1
        ;;
    close) exit 0 ;;
    add-note) exit 0 ;;
    *) exit 1 ;;
esac
TKSTUB4
chmod +x "${FAKE_BIN}/tk"

# Modify ticket A to include #bash and #opus modifiers
cat > "${TICKET_DATA_DIR}/${TICKET_A}" << EOF
Troothfairy: file_a.md

--- Tag #ƒ (explicit instruction) at line 1 ---
- #ƒ Run this script and check output #bash #opus

EOF

rm -f "$TK_LOG" "$CLAUDE_LOG"
touch "$TK_LOG" "$CLAUDE_LOG"
export CLAUDE_FAIL_TICKET=""

ORCH_MOD_OUTPUT=$("$ORCHESTRATOR" "$VAULT_DIR" 2>&1)

if [[ -f "$CLAUDE_LOG" ]]; then
    CLAUDE_MOD=$(cat "$CLAUDE_LOG")
else
    CLAUDE_MOD=""
fi

# 22. #opus modifier sets model to opus
assert_contains "opus modifier sets --model opus" "--model opus" "$CLAUDE_MOD"

# 23. #bash modifier adds Bash to allowedTools
assert_contains "bash modifier adds Bash tool" "Bash" "$CLAUDE_MOD"

echo ""

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
printf 'Results: %d passed, %d failed.\n' "$PASS" "$FAIL"
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
