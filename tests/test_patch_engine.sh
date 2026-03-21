#!/usr/bin/env bash
# test_patch_engine.sh — deterministic patch engine contract tests

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/tag_policy.sh"
source "$REPO_ROOT/scripts/patch_engine.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc (expected: $expected, actual: $actual)"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc (missing: $needle)"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc (unexpected: $needle)"
    fi
}

TMPDIR_ROOT="$(mktemp -d)"
cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

make_job() {
    local path="$1"
    local file_path="$2"
    local line_number="$3"
    local tag_char="$4"
    local route="$5"
    local tagged_line="$6"
    local block_content="$7"

    jq -n \
        --argjson schema_version "$(block_job_schema_version)" \
        --arg file_path "$file_path" \
        --arg vault_rel "note" \
        --arg file_basename "$(basename "$file_path")" \
        --argjson line_number "$line_number" \
        --arg tag_char "$tag_char" \
        --arg tag_label "$(policy_tag_label "$tag_char")" \
        --arg route "$route" \
        --argjson needs_full_file false \
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
        }' > "$path"
}

make_result() {
    local path="$1"
    local job_id="$2"
    local tag="$3"
    local outcome="$4"
    local completion_tag="$5"
    local append_failure_marker="$6"
    shift 6

    local response_lines_json
    if [[ $# -gt 0 ]]; then
        response_lines_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    else
        response_lines_json='[]'
    fi

    jq -n \
        --argjson schema_version "$(result_schema_version)" \
        --arg job_id "$job_id" \
        --arg tag "$tag" \
        --arg outcome "$outcome" \
        --arg completion_tag "$completion_tag" \
        --argjson append_failure_marker "$append_failure_marker" \
        --argjson response_lines "$response_lines_json" \
        '{
            schema_version: $schema_version,
            job_id: $job_id,
            tag: $tag,
            outcome: $outcome,
            completion_tag: $completion_tag,
            append_failure_marker: $append_failure_marker,
            response_lines: $response_lines
        }' > "$path"
}

echo "=== Suite 1: successful enrichment inserts nested bullets ==="
FILE_ONE="${TMPDIR_ROOT}/one.md"
JOB_ONE="${TMPDIR_ROOT}/one.job.json"
RESULT_ONE="${TMPDIR_ROOT}/one.result.json"
cat > "$FILE_ONE" <<'EOF'
- #∆ Base claim
	- Existing child
EOF
make_job "$JOB_ONE" "$FILE_ONE" 1 "∆" "api-search" "- #∆ Base claim" $'- #∆ Base claim\n\t- Existing child'
make_result "$RESULT_ONE" "job-one" "∆" "success" "º" false "- #Ω∆ Added context." $'\t- #¬ https://example.com — source'
INSERTED_ONE="$(patch_engine_apply_intent "$FILE_ONE" "$JOB_ONE" "$RESULT_ONE" 1)"
FILE_ONE_TEXT="$(cat "$FILE_ONE")"
assert_eq "inserted two response lines" "2" "$INSERTED_ONE"
assert_contains "completion tag applied" "#º Base claim" "$FILE_ONE_TEXT"
assert_contains "response bullet inserted" "#Ω∆ Added context." "$FILE_ONE_TEXT"
assert_contains "nested source bullet preserved" "#¬ https://example.com — source" "$FILE_ONE_TEXT"

echo ""
echo "=== Suite 2: no-op success only swaps the completion tag ==="
FILE_TWO="${TMPDIR_ROOT}/two.md"
JOB_TWO="${TMPDIR_ROOT}/two.job.json"
RESULT_TWO="${TMPDIR_ROOT}/two.result.json"
cat > "$FILE_TWO" <<'EOF'
- #© Known correct fact
EOF
make_job "$JOB_TWO" "$FILE_TWO" 1 "©" "api-search" "- #© Known correct fact" "- #© Known correct fact"
make_result "$RESULT_TWO" "job-two" "©" "no_op_success" "™" false
INSERTED_TWO="$(patch_engine_apply_intent "$FILE_TWO" "$JOB_TWO" "$RESULT_TWO" 1)"
FILE_TWO_TEXT="$(cat "$FILE_TWO")"
assert_eq "no-op success inserts zero lines" "0" "$INSERTED_TWO"
assert_contains "fact-check correct completion applied" "#™ Known correct fact" "$FILE_TWO_TEXT"
assert_not_contains "no-op success inserts no response bullets" "#Ω©" "$FILE_TWO_TEXT"

echo ""
echo "=== Suite 3: degraded outcomes append the failure marker ==="
FILE_THREE="${TMPDIR_ROOT}/three.md"
JOB_THREE="${TMPDIR_ROOT}/three.job.json"
RESULT_THREE="${TMPDIR_ROOT}/three.result.json"
cat > "$FILE_THREE" <<'EOF'
- #∑ Needs full file context
EOF
make_job "$JOB_THREE" "$FILE_THREE" 1 "∑" "api-search" "- #∑ Needs full file context" "- #∑ Needs full file context"
make_result "$RESULT_THREE" "job-three" "∑" "degraded" "º" true "- #Ω∑ Degraded response."
patch_engine_apply_intent "$FILE_THREE" "$JOB_THREE" "$RESULT_THREE" 1 >/dev/null
FILE_THREE_TEXT="$(cat "$FILE_THREE")"
assert_contains "degraded completion includes failure marker" "#º #¡ Needs full file context" "$FILE_THREE_TEXT"
assert_contains "degraded response inserted" "#Ω∑ Degraded response." "$FILE_THREE_TEXT"

echo ""
echo "=== Suite 4: stale expected lines are re-resolved against fresh file contents ==="
FILE_FOUR="${TMPDIR_ROOT}/four.md"
JOB_FOUR_A="${TMPDIR_ROOT}/four-a.job.json"
JOB_FOUR_B="${TMPDIR_ROOT}/four-b.job.json"
RESULT_FOUR_A="${TMPDIR_ROOT}/four-a.result.json"
RESULT_FOUR_B="${TMPDIR_ROOT}/four-b.result.json"
cat > "$FILE_FOUR" <<'EOF'
- #∆ First line
- #$ Second line
EOF
make_job "$JOB_FOUR_A" "$FILE_FOUR" 1 "∆" "api-search" "- #∆ First line" "- #∆ First line"
make_job "$JOB_FOUR_B" "$FILE_FOUR" 2 '$' "local-agent" "- #$ Second line" "- #$ Second line"
make_result "$RESULT_FOUR_A" "job-four-a" "∆" "success" "º" false "- #Ω∆ First response."
make_result "$RESULT_FOUR_B" "job-four-b" '$' "success" "º" false "- #Ω$ Second response."
patch_engine_apply_intent "$FILE_FOUR" "$JOB_FOUR_A" "$RESULT_FOUR_A" 1 >/dev/null
patch_engine_apply_intent "$FILE_FOUR" "$JOB_FOUR_B" "$RESULT_FOUR_B" 2 >/dev/null
FILE_FOUR_TEXT="$(cat "$FILE_FOUR")"
assert_contains "first line patched" "#º First line" "$FILE_FOUR_TEXT"
assert_contains "second line re-resolved and patched" "#º Second line" "$FILE_FOUR_TEXT"
assert_contains "second line response inserted" "#Ω$ Second response." "$FILE_FOUR_TEXT"

echo ""
echo "=== Suite 5: every configured tag exposes deterministic completion rules ==="
while IFS= read -r tag_char; do
    if [[ -z "$(policy_tag_route "$tag_char")" ]]; then
        fail "tag #${tag_char} has route"
    fi
    if [[ -z "$(policy_tag_completion "$tag_char" degraded)" ]]; then
        fail "tag #${tag_char} has degraded completion"
    fi
    case "$tag_char" in
        '©')
            if [[ -z "$(policy_tag_completion "$tag_char" correct)" ]]; then
                fail "tag #${tag_char} has correct completion"
            fi
            ;;
        *)
            if [[ -z "$(policy_tag_completion "$tag_char" success)" ]]; then
                fail "tag #${tag_char} has success completion"
            fi
            ;;
    esac
done < <(policy_tag_chars)

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
