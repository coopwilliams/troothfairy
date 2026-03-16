#!/usr/bin/env bash
# Run all tests in the tests/ directory
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
FAILED_TESTS=()

for test_file in "$TESTS_DIR"/test_*.sh; do
    [ -f "$test_file" ] || continue
    test_name="$(basename "$test_file")"
    echo "━━━ Running $test_name ━━━"
    if bash "$test_file"; then
        echo "✓ $test_name PASSED"
        ((PASS++))
    else
        echo "✗ $test_name FAILED"
        ((FAIL++))
        FAILED_TESTS+=("$test_name")
    fi
    echo ""
done

echo "━━━━━━━━━━━━━━━━━━━━━━"
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
