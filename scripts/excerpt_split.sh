#!/usr/bin/env bash
# excerpt_split.sh — deterministic splitter for excerpt search results
#
# Usage:
#   excerpt_split.sh <search-results-file> <splits-dir> <search-string> <context-lines>
#
# Converts `rga --heading` output into numbered excerpt chunk files, then applies
# deterministic file-type formatting rules to each chunk.

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $(basename "$0") <search-results-file> <splits-dir> <search-string> <context-lines>" >&2
    exit 1
fi

RESULTS_FILE="$1"
SPLITS_DIR="$2"
SEARCH_STRING="$3"
CONTEXT_LINES="$4"

[[ -f "$RESULTS_FILE" ]] || {
    echo "excerpt splitter: search results file not found: $RESULTS_FILE" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMATTER="${SCRIPT_DIR}/excerpt_format.sh"

mkdir -p "$SPLITS_DIR"
rm -f "${SPLITS_DIR}"/*

awk -v out_dir="$SPLITS_DIR" -v search_string="$SEARCH_STRING" -v context_lines="$CONTEXT_LINES" '
function flush(    out, pg) {
    gsub(/^\n+/, "", buf)
    gsub(/\n+$/, "", buf)
    if (buf != "") {
        n++
        out = out_dir "/" sprintf("%04d", n)
        printf "---\nagent-added: true\nfilepath: \"%s\"\nsearch_string: \"%s\"\ncontext_lines: %s\n", fname, search_string, context_lines > out
        if (page_start > 0) {
            printf "page_start: %d\npage_end: %d\n", page_start, page_end > out
        }
        printf "---\n\n%s\n", buf > out
        close(out)
        buf = ""
        page_start = 0
        page_end = 0
    }
}
/^--$/ { flush(); next }
/^\// { flush(); fname = $0; next }
/^$/ && buf == "" { next }
{
    line = $0
    if (match(line, /^Page [0-9]+: ?/)) {
        pg = int(substr(line, 6))
        if (page_start == 0 || pg < page_start) page_start = pg
        if (pg > page_end) page_end = pg
        line = substr(line, RSTART + RLENGTH)
    }
    buf = buf line "\n"
}
END { flush() }
' "$RESULTS_FILE"

if compgen -G "${SPLITS_DIR}/*" > /dev/null; then
    for chunk in "${SPLITS_DIR}"/*; do
        [[ -f "$chunk" ]] || continue
        "$FORMATTER" "$chunk"
    done
fi
