#!/usr/bin/env bash
# Verifies shell policy helpers resolve values from config/tag_policy.json.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO_ROOT/scripts/lib/config.sh"
source "$REPO_ROOT/scripts/lib/tag_policy.sh"

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

assert_contains_text() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc (missing: $needle)"
    fi
}

assert_eq "policy file resolves" "$REPO_ROOT/config/tag_policy.json" "$(resolve_tag_policy_file)"
assert_eq "result schema file resolves" "$REPO_ROOT/config/result-schema.json" "$(resolve_result_schema_file)"
assert_eq "#ƒ label comes from policy" "explicit instruction" "$(policy_tag_label 'ƒ')"
assert_eq "#∆ route comes from policy" "api-search" "$(policy_tag_route '∆')"
assert_eq "#∑ full-file flag comes from policy" "true" "$(policy_tag_needs_full_file '∑')"
assert_eq "#$ default model comes from policy" "haiku" "$(policy_tag_default_model '$')"
assert_eq "#© corrected completion comes from policy" "≠" "$(policy_tag_completion '©' corrected)"
assert_eq "api-search display name comes from policy" "API Search" "$(policy_route_display_name 'api-search')"
assert_eq "local-agent tools come from policy" "Read,Write,Bash" "$(policy_route_tools 'local-agent')"
assert_eq "hybrid enabled flag comes from policy" "false" "$(policy_route_enabled 'hybrid')"
assert_contains_text "route capability section mentions forbidden web on local-agent" "web_search" "$(policy_route_capability_section 'local-agent')"
assert_contains_text "tag section mentions #©" '#©' "$(policy_tag_section)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
