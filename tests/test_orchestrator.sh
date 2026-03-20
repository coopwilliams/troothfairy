#!/usr/bin/env bash
# test_orchestrator.sh — Integration tests for scripts/orchestrator.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORCHESTRATOR="${REPO_ROOT}/scripts/orchestrator.sh"

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

TMPDIR_ROOT=$(mktemp -d)
VAULT_DIR="${TMPDIR_ROOT}/vault"
FAKE_BIN="${TMPDIR_ROOT}/bin"
TICKET_DATA_DIR="${TMPDIR_ROOT}/ticket_data"
TK_LOG="${TMPDIR_ROOT}/tk_calls.log"
CLAUDE_LOG="${TMPDIR_ROOT}/claude_calls.log"
TK_LIST_FILE="${TMPDIR_ROOT}/ticket_list.txt"

mkdir -p "$VAULT_DIR" "$FAKE_BIN" "$TICKET_DATA_DIR"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

export TK_LOG
export CLAUDE_LOG
export TICKET_DATA_DIR
export TK_LIST_FILE
export STATUS_DIR="${TMPDIR_ROOT}/status"
mkdir -p "$STATUS_DIR"

write_job_json() {
    local path="$1"
    local file_path="$2"
    local file_basename="$3"
    local vault_rel="$4"
    local line_number="$5"
    local tag_char="$6"
    local tag_label="$7"
    local route="$8"
    local needs_full_file="$9"
    local tagged_line="${10}"
    local block_content="${11}"

    jq -n \
        --argjson schema_version 1 \
        --arg file_path "$file_path" \
        --arg file_basename "$file_basename" \
        --arg vault_rel "$vault_rel" \
        --argjson line_number "$line_number" \
        --arg tag_char "$tag_char" \
        --arg tag_label "$tag_label" \
        --arg route "$route" \
        --argjson needs_full_file "$needs_full_file" \
        --arg tagged_line "$tagged_line" \
        --arg block_content "$block_content" \
        '{
            schema_version: $schema_version,
            file_path: $file_path,
            file_basename: $file_basename,
            vault_rel: $vault_rel,
            line_number: $line_number,
            tag_char: $tag_char,
            tag_label: $tag_label,
            route: $route,
            needs_full_file: $needs_full_file,
            tagged_line: $tagged_line,
            block_content: $block_content
        }' > "$path"
}

cat > "${FAKE_BIN}/tk" << 'TKSTUB'
#!/usr/bin/env bash
printf '<<TK-CALL>> %s\n' "$*" >> "$TK_LOG"

case "$1" in
    list)
        [[ -f "$TK_LIST_FILE" ]] && cat "$TK_LIST_FILE"
        exit 0
        ;;
    show)
        ticket_id="$2"
        show_file="${TICKET_DATA_DIR}/${ticket_id}.json"
        [[ -f "$show_file" ]] && { cat "$show_file"; exit 0; }
        exit 1
        ;;
    close)
        exit 0
        ;;
    add-note)
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
TKSTUB
chmod +x "${FAKE_BIN}/tk"

cat > "${FAKE_BIN}/claude" << 'CLAUDESTUB'
#!/usr/bin/env bash
full_args="$*"
printf '<<CLAUDE-CALL>>\n%s\n<<END-CLAUDE-CALL>>\n' "$full_args" >> "$CLAUDE_LOG"

prompt=""
tools=""
model=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p)
            prompt="$2"
            shift 2
            ;;
        --allowedTools)
            tools="$2"
            shift 2
            ;;
        --model)
            model="$2"
            shift 2
            ;;
        --system-prompt)
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

ticket_id=$(printf '%s\n' "$prompt" | awk -F': ' '/^Ticket ID:/ { print $2; exit }')
tag_char=$(printf '%s\n' "$prompt" | sed -n 's/^Tag: #\(.\).*/\1/p' | head -1)

if [[ -n "$CLAUDE_FAIL_TICKET" && "$ticket_id" == "$CLAUDE_FAIL_TICKET" ]]; then
    echo "simulated failure for $ticket_id" >&2
    exit 1
fi

if [[ "$ticket_id" == "ticket-a" ]]; then
    cat <<EOF
{
  "schema_version": 1,
  "job_id": "ticket-a",
  "tag": "∆",
  "outcome": "success",
  "completion_tag": "º",
  "append_failure_marker": false,
  "response_lines": [
    "- #Ω∆ Added context for the transformer note.",
    "\t- #¬ https://arxiv.org/abs/1706.03762 — Attention Is All You Need"
  ]
}
EOF
    exit 0
fi

if [[ "$ticket_id" == "ticket-b" ]]; then
    cat <<EOF
{
  "schema_version": 1,
  "job_id": "ticket-b",
  "tag": "©",
  "outcome": "no_op_success",
  "completion_tag": "™",
  "append_failure_marker": false,
  "response_lines": []
}
EOF
    exit 0
fi

if [[ "$ticket_id" == "ticket-c" ]]; then
    cat <<EOF
{
  "schema_version": 1,
  "job_id": "ticket-c",
  "tag": "∑",
  "outcome": "success",
  "completion_tag": "º",
  "append_failure_marker": false,
  "response_lines": [
    "- #Ω∑ Uses full-file context correctly."
  ]
}
EOF
    exit 0
fi

if [[ "$ticket_id" == "ticket-local" ]]; then
    cat <<'EOF'
Perfect! The excerpt-text job is complete.

```json
{
  "schema_version": 1,
  "job_id": "ticket-local",
  "tag": "$",
  "outcome": "success",
  "completion_tag": "º",
  "append_failure_marker": false,
  "response_lines": [
    "- #Ω$ Local shell-assisted response."
  ]
}
```
EOF
    exit 0
fi

if [[ "$ticket_id" == "ticket-bad-json" ]]; then
    printf 'not-json\n'
    exit 0
fi

cat <<EOF
{
  "schema_version": 1,
  "job_id": "${ticket_id}",
  "tag": "${tag_char}",
  "outcome": "success",
  "completion_tag": "º",
  "append_failure_marker": false,
  "response_lines": []
}
EOF
CLAUDESTUB
chmod +x "${FAKE_BIN}/claude"

export PATH="${FAKE_BIN}:${PATH}"

build_success_fixture() {
    rm -rf "$VAULT_DIR" "$TICKET_DATA_DIR" "$STATUS_DIR"
    mkdir -p "$VAULT_DIR" "$TICKET_DATA_DIR" "$STATUS_DIR"
    : > "$TK_LOG"
    : > "$CLAUDE_LOG"
    : > "$TK_LIST_FILE"

    cat > "${VAULT_DIR}/file_a.md" << 'EOF'
- #∆ Transformer models use self-attention.
	- Child context bullet
- #© The speed of light is approximately 3e8 m/s.
EOF

    cat > "${VAULT_DIR}/file_b.md" << 'EOF'
- #∑ Evaluate this with full context
	- Related sub-bullet
EOF

    printf '%s\n' "ticket-a" >> "$TK_LIST_FILE"
    printf '%s\n' "ticket-b" >> "$TK_LIST_FILE"
    printf '%s\n' "ticket-c" >> "$TK_LIST_FILE"

    write_job_json "${TICKET_DATA_DIR}/ticket-a.json" \
        "${VAULT_DIR}/file_a.md" "file_a.md" "file_a" 1 "∆" "evaluate and enrich" "api-search" false \
        "- #∆ Transformer models use self-attention." \
        $'- #∆ Transformer models use self-attention.\n\t- Child context bullet'

    write_job_json "${TICKET_DATA_DIR}/ticket-b.json" \
        "${VAULT_DIR}/file_a.md" "file_a.md" "file_a" 3 "©" "validate/check" "api-search" false \
        "- #© The speed of light is approximately 3e8 m/s." \
        "- #© The speed of light is approximately 3e8 m/s."

    write_job_json "${TICKET_DATA_DIR}/ticket-c.json" \
        "${VAULT_DIR}/file_b.md" "file_b.md" "file_b" 1 "∑" "evaluate with full file context" "api-search" true \
        "- #∑ Evaluate this with full context" \
        $'- #∑ Evaluate this with full context\n\t- Related sub-bullet'
}

echo "=== Suite 1: Successful block jobs with deterministic patching ==="
build_success_fixture
export CLAUDE_FAIL_TICKET=""

ORCH_OUTPUT=$("$ORCHESTRATOR" "$VAULT_DIR" 2>&1)
ORCH_EXIT=$?

assert_eq "orchestrator exits with code 0" "0" "$ORCH_EXIT"

TK_ALL=$(cat "$TK_LOG")
CLAUDE_ALL=$(cat "$CLAUDE_LOG")
FILE_A=$(cat "${VAULT_DIR}/file_a.md")
FILE_B=$(cat "${VAULT_DIR}/file_b.md")

assert_contains "tk list called with --status=open" "--status=open" "$TK_ALL"
assert_contains "tk show called for ticket-a" "show ticket-a" "$TK_ALL"
assert_contains "tk show called for ticket-b" "show ticket-b" "$TK_ALL"
assert_contains "tk show called for ticket-c" "show ticket-c" "$TK_ALL"
assert_contains "ticket-a closed after patch" "close ticket-a" "$TK_ALL"
assert_contains "ticket-b closed after patch" "close ticket-b" "$TK_ALL"
assert_contains "ticket-c closed after patch" "close ticket-c" "$TK_ALL"

claude_call_count=$(grep -c '<<CLAUDE-CALL>>' "$CLAUDE_LOG" || true)
assert_eq "three claude calls for three block jobs" "3" "$claude_call_count"
assert_contains "api route uses web tools" "WebSearch,WebFetch" "$CLAUDE_ALL"
assert_not_contains "api route excludes Bash" "Read,Write,Bash" "$CLAUDE_ALL"
assert_contains "prompt includes JSON contract" '"schema_version": 1' "$CLAUDE_ALL"
assert_contains "prompt includes full file content for ∑" "Related sub-bullet" "$CLAUDE_ALL"

assert_contains "line 1 tag was completed" "#º Transformer models use self-attention." "$FILE_A"
assert_contains "line 1 response inserted" "#Ω∆ Added context for the transformer note." "$FILE_A"
assert_contains "line 3 fact-check became #™" "#™ The speed of light is approximately 3e8 m/s." "$FILE_A"
assert_not_contains "no extra response inserted for no-op success" "#Ω©" "$FILE_A"
assert_contains "full-context file patched" "#Ω∑ Uses full-file context correctly." "$FILE_B"

echo ""

echo "=== Suite 2: One worker fails, others still patch ==="
build_success_fixture
export CLAUDE_FAIL_TICKET="ticket-c"

ORCH_FAIL_OUTPUT=$("$ORCHESTRATOR" "$VAULT_DIR" 2>&1)
ORCH_FAIL_EXIT=$?

TK_FAIL=$(cat "$TK_LOG")
FILE_A_FAIL=$(cat "${VAULT_DIR}/file_a.md")
FILE_B_FAIL=$(cat "${VAULT_DIR}/file_b.md")

if [[ "$ORCH_FAIL_EXIT" -ne 0 ]]; then
    pass "orchestrator exits non-zero when one worker fails"
else
    fail "orchestrator should exit non-zero when one worker fails"
fi

assert_contains "successful ticket-a still closes" "close ticket-a" "$TK_FAIL"
assert_contains "successful ticket-b still closes" "close ticket-b" "$TK_FAIL"
assert_contains "degraded ticket-c still closes" "close ticket-c" "$TK_FAIL"
assert_contains "degraded ticket-c gets add-note" "add-note ticket-c" "$TK_FAIL"
assert_contains "degraded note recorded" "Degraded:" "$TK_FAIL"
assert_contains "file_a still patched in failure suite" "#Ω∆ Added context for the transformer note." "$FILE_A_FAIL"
assert_contains "failed file_b gets degraded marker" "#º #¡ Evaluate this with full context" "$FILE_B_FAIL"
assert_contains "failed file_b gets degraded response" "#Ω∑ The agent failed before returning a structured result." "$FILE_B_FAIL"

echo ""

echo "=== Suite 3: Local-agent route uses Bash and no web ==="
rm -rf "$VAULT_DIR" "$TICKET_DATA_DIR" "$STATUS_DIR"
mkdir -p "$VAULT_DIR" "$TICKET_DATA_DIR" "$STATUS_DIR"
: > "$TK_LOG"
: > "$CLAUDE_LOG"
printf '%s\n' "ticket-local" > "$TK_LIST_FILE"
export CLAUDE_FAIL_TICKET=""

cat > "${VAULT_DIR}/local.md" << 'EOF'
- #$ Run this script and inspect output #opus
EOF

write_job_json "${TICKET_DATA_DIR}/ticket-local.json" \
    "${VAULT_DIR}/local.md" "local.md" "local" 1 '$' "instruction with shell access" "local-agent" false \
    "- #$ Run this script and inspect output #opus" \
    "- #$ Run this script and inspect output #opus"

ORCH_LOCAL_OUTPUT=$("$ORCHESTRATOR" "$VAULT_DIR" 2>&1)
ORCH_LOCAL_EXIT=$?
CLAUDE_LOCAL=$(cat "$CLAUDE_LOG")
LOCAL_FILE=$(cat "${VAULT_DIR}/local.md")

assert_eq "local-agent suite exits 0" "0" "$ORCH_LOCAL_EXIT"
assert_contains "local-agent uses opus override" "--model opus" "$CLAUDE_LOCAL"
assert_contains "local-agent uses Bash tools" "Read,Write,Bash" "$CLAUDE_LOCAL"
assert_not_contains "local-agent excludes web tools" "WebSearch,WebFetch" "$CLAUDE_LOCAL"
assert_contains "configured directories included for local-agent" "Configured directories" "$CLAUDE_LOCAL"
assert_contains "excerpt dir resolves under vault path" "${VAULT_DIR}/_EXCERPTS [write-only]" "$CLAUDE_LOCAL"
assert_not_contains "excerpt dir is not repo-root relative" "${REPO_ROOT}/./_EXCERPTS" "$CLAUDE_LOCAL"
assert_contains "local-agent patch applied" "#Ω$ Local shell-assisted response." "$LOCAL_FILE"

echo ""

echo "=== Suite 4: Disabled hybrid route is rejected without claude call ==="
rm -rf "$VAULT_DIR" "$TICKET_DATA_DIR" "$STATUS_DIR"
mkdir -p "$VAULT_DIR" "$TICKET_DATA_DIR" "$STATUS_DIR"
: > "$TK_LOG"
: > "$CLAUDE_LOG"
printf '%s\n' "ticket-hybrid" > "$TK_LIST_FILE"

cat > "${VAULT_DIR}/hybrid.md" << 'EOF'
- #ƒ This should not run
EOF

write_job_json "${TICKET_DATA_DIR}/ticket-hybrid.json" \
    "${VAULT_DIR}/hybrid.md" "hybrid.md" "hybrid" 1 "ƒ" "explicit instruction" "hybrid" false \
    "- #ƒ This should not run" \
    "- #ƒ This should not run"

ORCH_HYBRID_OUTPUT=$("$ORCHESTRATOR" "$VAULT_DIR" 2>&1)
ORCH_HYBRID_EXIT=$?
TK_HYBRID=$(cat "$TK_LOG")
CLAUDE_HYBRID=$(cat "$CLAUDE_LOG")

if [[ "$ORCH_HYBRID_EXIT" -ne 0 ]]; then
    pass "hybrid suite exits non-zero"
else
    fail "hybrid suite should exit non-zero"
fi

assert_contains "hybrid ticket gets add-note" "add-note ticket-hybrid" "$TK_HYBRID"
assert_contains "hybrid failure mentions disabled route" "Stub route. Do not execute until a safe design exists." "$TK_HYBRID"
assert_eq "hybrid route makes no claude call" "0" "$(grep -c '<<CLAUDE-CALL>>' "$CLAUDE_LOG" || true)"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
