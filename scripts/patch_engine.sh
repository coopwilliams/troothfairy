#!/usr/bin/env bash
# patch_engine.sh — deterministic patch application for Troothfairy block jobs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/lib/config.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/tag_policy.sh" 2>/dev/null || true

patch_engine_infer_child_indent() {
    local tagged_line="$1"
    local block_content="$2"
    local base_indent=""
    local next_line=""

    if [[ "$tagged_line" =~ ^([[:space:]]*) ]]; then
        base_indent="${BASH_REMATCH[1]}"
    fi

    next_line=$(printf '%s\n' "$block_content" | awk 'NR > 1 && NF { print; exit }')
    if [[ -n "$next_line" ]] && [[ "$next_line" =~ ^([[:space:]]*) ]]; then
        local next_indent="${BASH_REMATCH[1]}"
        if [[ ${#next_indent} -gt ${#base_indent} ]]; then
            printf '%s\n' "${next_indent:${#base_indent}}"
            return 0
        fi
    fi

    if [[ "$base_indent" == *$'\t'* ]]; then
        printf '\t\n'
    else
        printf '    \n'
    fi
}

patch_engine_find_target_line() {
    local file_path="$1"
    local expected_line="$2"
    local tagged_line="$3"

    local current_line
    current_line=$(sed -n "${expected_line}p" "$file_path" 2>/dev/null || true)
    if [[ "$current_line" == "$tagged_line" ]]; then
        printf '%s\n' "$expected_line"
        return 0
    fi

    awk -v target="$tagged_line" '
    $0 == target { print NR; exit }
    ' "$file_path"
}

patch_engine_apply_intent() {
    local file_path="$1"
    local job_file="$2"
    local result_file="$3"
    local expected_line="$4"

    local tagged_line block_content completion_tag append_failure_marker
    local target_line replaced_line indent_unit child_prefix
    local tmp_file line_no inserted_count response_count

    [[ -f "$file_path" ]] || {
        echo "patch-engine: source file not found: $file_path" >&2
        return 1
    }
    [[ -f "$job_file" ]] || {
        echo "patch-engine: job payload not found: $job_file" >&2
        return 1
    }
    [[ -f "$result_file" ]] || {
        echo "patch-engine: patch intent not found: $result_file" >&2
        return 1
    }

    validate_block_job_payload_file "$job_file" >/dev/null 2>&1 || {
        echo "patch-engine: invalid block-job payload" >&2
        return 1
    }
    validate_result_payload_file "$result_file" >/dev/null 2>&1 || {
        echo "patch-engine: invalid patch intent payload" >&2
        return 1
    }

    tagged_line=$(jq -r '.tagged_line' "$job_file")
    block_content=$(jq -r '.block_content' "$job_file")
    completion_tag=$(jq -r '.completion_tag' "$result_file")
    append_failure_marker=$(jq -r '.append_failure_marker' "$result_file")

    target_line=$(patch_engine_find_target_line "$file_path" "$expected_line" "$tagged_line")
    if [[ -z "$target_line" ]]; then
        echo "patch-engine: could not locate tagged line in ${file_path}" >&2
        return 1
    fi

    replaced_line=$(printf '%s\n' "$tagged_line" | perl -CSDA -e '
        use utf8;
        my ($tag_token, $completion_token) = @ARGV;
        local $/;
        my $text = <STDIN>;
        $text =~ s/\Q$tag_token\E/$completion_token/;
        print $text;
    ' "#$(jq -r '.tag_char' "$job_file")" "#${completion_tag}")
    if [[ "$append_failure_marker" == "true" ]]; then
        replaced_line=$(printf '%s\n' "$replaced_line" | perl -CSDA -e '
            use utf8;
            my ($completion_token) = @ARGV;
            local $/;
            my $text = <STDIN>;
            $text =~ s/\Q$completion_token\E/$completion_token #¡/;
            print $text;
        ' "#${completion_tag}")
    fi

    if [[ "$tagged_line" =~ ^([[:space:]]*) ]]; then
        child_prefix="${BASH_REMATCH[1]}"
    else
        child_prefix=""
    fi
    indent_unit=$(patch_engine_infer_child_indent "$tagged_line" "$block_content")
    child_prefix="${child_prefix}${indent_unit}"

    tmp_file=$(mktemp)
    line_no=0
    inserted_count=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        if [[ "$line_no" -eq "$target_line" ]]; then
            printf '%s\n' "$replaced_line" >> "$tmp_file"
            response_count=$(jq -r '.response_lines | length' "$result_file")
            if [[ "$response_count" -gt 0 ]]; then
                while IFS= read -r response_line; do
                    printf '%s%s\n' "$child_prefix" "$response_line" >> "$tmp_file"
                    inserted_count=$((inserted_count + 1))
                done < <(jq -r '.response_lines[]' "$result_file")
            fi
        else
            printf '%s\n' "$line" >> "$tmp_file"
        fi
    done < "$file_path"

    mv "$tmp_file" "$file_path"
    printf '%s\n' "$inserted_count"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-}"
    case "$cmd" in
        apply)
            [[ $# -eq 5 ]] || {
                echo "usage: patch_engine.sh apply <file_path> <job_file> <result_file> <expected_line>" >&2
                exit 1
            }
            patch_engine_apply_intent "$2" "$3" "$4" "$5"
            ;;
        *)
            echo "usage: patch_engine.sh apply <file_path> <job_file> <result_file> <expected_line>" >&2
            exit 1
            ;;
    esac
fi
