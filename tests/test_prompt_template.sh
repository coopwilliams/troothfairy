#!/usr/bin/env bash
# test_prompt_template.sh
# Verifies that scripts/prompts/subagent-system.md exists and contains all required elements.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATE="$REPO_ROOT/scripts/prompts/subagent-system.md"

PASS=0
FAIL=0

assert_contains() {
    local description="$1"
    local pattern="$2"
    if grep -qF -- "$pattern" "$TEMPLATE" 2>/dev/null; then
        echo "PASS: $description"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $description (pattern not found: $pattern)"
        FAIL=$((FAIL + 1))
    fi
}

# ── File existence and non-emptiness ─────────────────────────────────────────

if [ -f "$TEMPLATE" ]; then
    echo "PASS: template file exists"
    PASS=$((PASS + 1))
else
    echo "FAIL: template file does not exist at $TEMPLATE"
    FAIL=$((FAIL + 1))
fi

if [ -s "$TEMPLATE" ]; then
    echo "PASS: template file is non-empty"
    PASS=$((PASS + 1))
else
    echo "FAIL: template file is empty"
    FAIL=$((FAIL + 1))
fi

# ── Required tag references ───────────────────────────────────────────────────

assert_contains "contains user tag #ƒ"  "#ƒ"
assert_contains "contains user tag #∆"  "#∆"
assert_contains "contains user tag #∑"  "#∑"
assert_contains "contains user tag #©"  "#©"
assert_contains "contains agent tag #Ω" "#Ω"
assert_contains "contains agent tag #¬" "#¬"
assert_contains "contains agent tag #§" "#§"
assert_contains "contains agent tag #¡" "#¡"
assert_contains "contains completion tag #º" "#º"
assert_contains "contains completion tag #™" "#™"
assert_contains "contains completion tag #≠" "#≠"

# ── Sourcing guide principles ─────────────────────────────────────────────────

assert_contains "sourcing: never pull-quote"             "never pull-quote"
assert_contains "sourcing: prefer primary sources"       "Prefer primary sources"
assert_contains "sourcing: blacklist runtime injection"  "blacklist will be injected at runtime"
assert_contains "sourcing: whitelist runtime injection"  "whitelist will be injected at runtime"
assert_contains "sourcing: contested/political topics"   "contested or political"
assert_contains "sourcing: no good source fallback"      "no good source exists"

# ── Failure handling ──────────────────────────────────────────────────────────

assert_contains "failure: #¡ after completion tag"        "#¡"
assert_contains "failure: user tag always consumed"      "user tag is always consumed"

# ── General principles ────────────────────────────────────────────────────────

assert_contains "principle: no fabricated quotes"        "Never fabricate quotes"
assert_contains "principle: do not modify outside block" "outside the specific block"

# ── Examples section ──────────────────────────────────────────────────────────

assert_contains "examples section exists"                "## Examples"
assert_contains "example: #∆ block present"              "Example 1"
assert_contains "example: #© correct case present"       "Example 2"
assert_contains "example: #© incorrect case present"     "Example 3"
assert_contains "example: #ƒ instruction present"        "Example 4"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

exit 0
