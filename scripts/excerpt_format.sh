#!/usr/bin/env bash
# excerpt_format.sh — deterministic formatter for excerpt chunk files
#
# Usage:
#   excerpt_format.sh <excerpt-file>
#
# Detects the source file type from excerpt frontmatter and applies
# deterministic formatting rules to the body only.

set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $(basename "$0") <excerpt-file>" >&2
    exit 1
fi

excerpt_file="$1"
[[ -f "$excerpt_file" ]] || {
    echo "excerpt formatter: file not found: $excerpt_file" >&2
    exit 1
}

source_ext=$(
    awk '
        BEGIN { in_frontmatter = 0; dash_count = 0 }
        /^---$/ {
            dash_count++
            if (dash_count == 1) {
                in_frontmatter = 1
                next
            }
            if (dash_count == 2) {
                exit
            }
        }
        in_frontmatter && /^filepath:[[:space:]]*"/ {
            line = $0
            sub(/^filepath:[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            print line
            exit
        }
    ' "$excerpt_file" | awk '
        {
            n = split($0, parts, /\./)
            if (n > 1) {
                print tolower(parts[n])
            }
        }
    '
)

python3 - "$excerpt_file" "${source_ext:-}" <<'PY'
import pathlib
import re
import sys


def split_frontmatter(text: str):
    if not text.startswith("---\n"):
        return "", text
    marker = "\n---\n"
    end = text.find(marker, 4)
    if end == -1:
        return "", text
    frontmatter = text[: end + len(marker)]
    body = text[end + len(marker) :]
    return frontmatter, body


def normalize_pdf_body(body: str) -> str:
    sentence_end_re = re.compile(r'[.!?](?:["\'\)\]\u201d\u2019]+)?$')
    speaker_re = re.compile(r'^[A-Z][A-Z0-9&.\-]{0,20}:')
    list_re = re.compile(r'^(?:[-*]\s|\d+\.\s)')
    short_artifact_re = re.compile(
        r'^(?:'
        r'[A-Z][A-Z\s.\-]{3,}|'
        r'\d+|'
        r'\d{1,2}/\d{1,2}/\d{2,4},?\s+\d{1,2}:\d{2}(?:\s?[AP]M)?|'
        r'[\w.-]+\.(?:p\d+|pdf|epub|txt|docx?)'
        r')$'
    )

    def should_preserve_break(left: str, right: str) -> bool:
        left = left.rstrip()
        right = right.lstrip()
        if not left or not right:
            return True
        if sentence_end_re.search(left):
            return True
        if speaker_re.match(right):
            return True
        if list_re.match(right):
            return True
        if short_artifact_re.match(left) or short_artifact_re.match(right):
            return True
        return False

    paragraphs = re.split(r'(\n\s*\n)', body)
    normalized_parts = []
    for part in paragraphs:
        if re.fullmatch(r'\n\s*\n', part):
            normalized_parts.append(part)
            continue
        lines = part.splitlines()
        if not lines:
            normalized_parts.append(part)
            continue
        current = lines[0]
        for line in lines[1:]:
            if should_preserve_break(current, line):
                current += "\n" + line
            else:
                current += " " + line.lstrip()
        normalized_parts.append(current)
    return "".join(normalized_parts)


path = pathlib.Path(sys.argv[1])
source_ext = sys.argv[2]
text = path.read_text()
frontmatter, body = split_frontmatter(text)

if source_ext == "pdf":
    body = normalize_pdf_body(body)

path.write_text(frontmatter + body)
PY
