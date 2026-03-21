#!/usr/bin/env bash
# test_excerpt_split.sh — Tests for deterministic excerpt splitting/formatting

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SPLITTER="${REPO_ROOT}/scripts/excerpt_split.sh"

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
        fail "$desc — expected to contain '$needle'"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc — expected not to contain '$needle'"
    fi
}

TMPDIR_ROOT=$(mktemp -d)
RESULTS_FILE="${TMPDIR_ROOT}/results.txt"
SPLITS_DIR="${TMPDIR_ROOT}/splits"

cleanup() {
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

cat > "$RESULTS_FILE" <<'EOF'
/tmp/source/example.pdf
Page 18: Bill, were able to draw upon their devotion to feel connected to their teacher even if he or she was
absent. About being away from his teacher’s presence, Bill said that practice “never felt destabilizing
because there was some quality of being held [ . . . ] by his mind.”

Religions 2017, 8, 153

Page 19: For quite a few practitioners, though, feeling a deep connection with teachers could be difficult
even when they were present.
JJ: Is Valeria the ideal love for him?
GW: No.
JAMES B. JORDAN
109
4/17/2007, 2:47 PM
09chapnine.p65
bullet intro that should wrap with the next
- but this list item should stay separate
--
/tmp/source/example.txt
This plain text excerpt
should keep its line breaks.
EOF

"$SPLITTER" "$RESULTS_FILE" "$SPLITS_DIR" "embarrass|humiliat|ashamed|shame" "15"

chunk_count=$(find "$SPLITS_DIR" -maxdepth 1 -type f | wc -l | tr -d ' ')
assert_eq "splitter creates two chunk files" "2" "$chunk_count"

PDF_CHUNK=$(sed -n '1,220p' "${SPLITS_DIR}/0001")
TXT_CHUNK=$(sed -n '1,220p' "${SPLITS_DIR}/0002")

assert_contains "pdf chunk includes filepath frontmatter" 'filepath: "/tmp/source/example.pdf"' "$PDF_CHUNK"
assert_contains "pdf chunk records page range" 'page_start: 18' "$PDF_CHUNK"
assert_contains "pdf chunk records page range end" 'page_end: 19' "$PDF_CHUNK"
assert_contains "pdf formatter joins wrapped sentence line" 'he or she was absent. About being away' "$PDF_CHUNK"
assert_contains "pdf formatter joins second wrapped sentence line" 'teachers could be difficult even when they were present.' "$PDF_CHUNK"
assert_not_contains "pdf formatter does not merge header artifact into prior sentence" 'mind.” Religions 2017, 8, 153' "$PDF_CHUNK"
assert_not_contains "pdf formatter removes original single wrapped newline" $'he or she was\nabsent.' "$PDF_CHUNK"
assert_contains "pdf formatter preserves speaker-turn break after period" $'present.\nJJ: Is Valeria the ideal love for him?' "$PDF_CHUNK"
assert_contains "pdf formatter preserves speaker-turn break between labels" $'JJ: Is Valeria the ideal love for him?\nGW: No.' "$PDF_CHUNK"
assert_contains "pdf formatter preserves all-caps artifact line" $'GW: No.\nJAMES B. JORDAN' "$PDF_CHUNK"
assert_contains "pdf formatter preserves numeric artifact line" $'JAMES B. JORDAN\n109' "$PDF_CHUNK"
assert_contains "pdf formatter preserves date artifact line" $'109\n4/17/2007, 2:47 PM' "$PDF_CHUNK"
assert_contains "pdf formatter preserves filename artifact line" $'4/17/2007, 2:47 PM\n09chapnine.p65' "$PDF_CHUNK"
assert_contains "pdf formatter preserves list-item break" $'bullet intro that should wrap with the next\n- but this list item should stay separate' "$PDF_CHUNK"
assert_not_contains "pdf formatter does not flatten speaker turn after punctuation" 'present. JJ: Is Valeria the ideal love for him?' "$PDF_CHUNK"

assert_contains "non-pdf chunk includes filepath frontmatter" 'filepath: "/tmp/source/example.txt"' "$TXT_CHUNK"
assert_contains "non-pdf chunk preserves body newlines" $'This plain text excerpt\nshould keep its line breaks.' "$TXT_CHUNK"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
