#!/usr/bin/env bash
# Verifies that structured policy and prompt templates exist and include required elements.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
POLICY="$REPO_ROOT/config/tag_policy.json"
BLOCK_JOB_SCHEMA="$REPO_ROOT/config/block-job-schema.json"
RESULT_SCHEMA="$REPO_ROOT/config/result-schema.json"
SYSTEM_TEMPLATE="$REPO_ROOT/scripts/prompts/system.tmpl.md"
JOB_TEMPLATE="$REPO_ROOT/scripts/prompts/job.tmpl.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_file() {
    local desc="$1" path="$2"
    if [[ -s "$path" ]]; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

assert_contains() {
    local desc="$1" pattern="$2" path="$3"
    if grep -qF -- "$pattern" "$path" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc (pattern not found: $pattern)"
    fi
}

assert_jq() {
    local desc="$1" query="$2" expected="$3" path="$4"
    local actual
    actual=$(jq -r "$query" "$path" 2>/dev/null || true)
    if [[ "$actual" == "$expected" ]]; then
        pass "$desc"
    else
        fail "$desc (expected: $expected, actual: $actual)"
    fi
}

assert_file "policy file exists" "$POLICY"
assert_file "block-job schema exists" "$BLOCK_JOB_SCHEMA"
assert_file "result schema exists" "$RESULT_SCHEMA"
assert_file "system template exists" "$SYSTEM_TEMPLATE"
assert_file "job template exists" "$JOB_TEMPLATE"

assert_jq "policy schema version is 1" '.schema_version' '1' "$POLICY"
assert_jq "block-job schema version is 1" '.schema_version' '1' "$BLOCK_JOB_SCHEMA"
assert_jq "route for #∆ is api-search" '.tags["∆"].route' 'api-search' "$POLICY"
assert_jq "route for #$ is local-agent" '.tags["$"].route' 'local-agent' "$POLICY"
assert_jq "full-file flag for #∑ is true" '.tags["∑"].needs_full_file' 'true' "$POLICY"
assert_jq "default model for #$ is haiku" '.tags["$"].default_model' 'haiku' "$POLICY"
assert_jq "completion tag for #© correct is ™" '.tags["©"].completion.correct' '™' "$POLICY"
assert_jq "hybrid route is disabled" '.routes.hybrid.enabled' 'false' "$POLICY"
assert_jq "api-search tools are web-only" '.routes["api-search"].allowed_tools | join(",")' 'WebSearch,WebFetch' "$POLICY"

assert_contains "system template includes route capability placeholder" '{{ROUTE_CAPABILITY_SECTION}}' "$SYSTEM_TEMPLATE"
assert_contains "system template includes tag policy placeholder" '{{TAG_POLICY_SECTION}}' "$SYSTEM_TEMPLATE"
assert_contains "system template includes blacklist placeholder" '{{BLACKLIST_CONTENT}}' "$SYSTEM_TEMPLATE"
assert_contains "system template includes whitelist placeholder" '{{WHITELIST_CONTENT}}' "$SYSTEM_TEMPLATE"

assert_contains "job template includes ticket placeholder" '{{TICKET_ID}}' "$JOB_TEMPLATE"
assert_contains "job template includes route placeholder" '{{ROUTE_ID}}' "$JOB_TEMPLATE"
assert_contains "job template includes tagged line placeholder" '{{TAGGED_LINE}}' "$JOB_TEMPLATE"
assert_contains "job template includes result schema placeholder" '{{RESULT_SCHEMA_TEXT}}' "$JOB_TEMPLATE"
assert_contains "job template mentions #© no-op success rule" 'no-op success' "$JOB_TEMPLATE"

assert_jq "result schema version is 1" '.schema_version' '1' "$RESULT_SCHEMA"
assert_jq "result schema has completion_tag field" '.completion_tag' 'º' "$RESULT_SCHEMA"
assert_jq "every tag route resolves to a defined route" '. as $root | [$root.tags | to_entries[] | ($root.routes[.value.route] != null)] | all' 'true' "$POLICY"
assert_jq "every tag defines degraded completion" '[.tags | to_entries[] | (.value.completion.degraded != null)] | all' 'true' "$POLICY"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
