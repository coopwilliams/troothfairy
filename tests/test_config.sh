#!/usr/bin/env bash
# test_config.sh — config helper coverage for single and multi-vault setups

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_LIB="${SCRIPT_DIR}/../scripts/lib/config.sh"

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
        fail "$desc — expected to contain '$needle'"
    fi
}

TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

mkdir -p "${TMPDIR_ROOT}/repo" "${TMPDIR_ROOT}/vault-a" "${TMPDIR_ROOT}/vault-b"

CONFIG_FILE="${TMPDIR_ROOT}/repo/config.yaml"
export CONFIG_FILE

# shellcheck source=../scripts/lib/config.sh
source "$CONFIG_LIB"

cat > "$CONFIG_FILE" <<EOF
vault_path: ./vault-single
status_dir: ${TMPDIR_ROOT}/status
dirs:
  - ./sourcing/tags read
  - ./_EXCERPTS write
EOF

SINGLE_VAULT="$(resolve_vault_path)"
assert_eq "single vault_path resolves relative to config file" "${TMPDIR_ROOT}/repo/vault-single" "$SINGLE_VAULT"

SINGLE_DIRS="$(get_dirs "${TMPDIR_ROOT}/vault-a")"
assert_contains "get_dirs keeps repo-relative read path" "${TMPDIR_ROOT}/repo/sourcing/tags read" "$SINGLE_DIRS"
assert_contains "get_dirs resolves excerpt dir under active vault" "${TMPDIR_ROOT}/vault-a/_EXCERPTS write" "$SINGLE_DIRS"

cat > "$CONFIG_FILE" <<EOF
vault_path: ./vault-single
vaults:
  - ${TMPDIR_ROOT}/vault-a
  - ./vault-b
  - ${TMPDIR_ROOT}/vault-a
EOF

MULTI_VAULTS="$(resolve_vault_paths)"
FIRST_MULTI="$(printf '%s\n' "$MULTI_VAULTS" | sed -n '1p')"
SECOND_MULTI="$(printf '%s\n' "$MULTI_VAULTS" | sed -n '2p')"
THIRD_MULTI="$(printf '%s\n' "$MULTI_VAULTS" | sed -n '3p')"

assert_eq "vaults list first entry preserved" "${TMPDIR_ROOT}/vault-a" "$FIRST_MULTI"
assert_eq "vaults list relative entry resolves against config file" "${TMPDIR_ROOT}/repo/vault-b" "$SECOND_MULTI"
assert_eq "vaults list deduplicates repeated entries" "" "$THIRD_MULTI"
assert_eq "resolve_vault_path returns first configured vault" "${TMPDIR_ROOT}/vault-a" "$(resolve_vault_path)"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed."
if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
