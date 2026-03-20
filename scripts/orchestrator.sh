#!/usr/bin/env bash
# orchestrator.sh — Troothfairy block-job orchestrator
#
# Reads open troothfairy tickets created by the dispatcher, treats each ticket
# as a single tagged-block job, runs generation work in parallel, then applies
# deterministic patches per file in a serialized order.
#
# Usage: orchestrator.sh [vault_dir]
#
# Requires: bash 3.2+, claude CLI, tk CLI, jq

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

VAULT_DIR="${1:-${REPO_ROOT}/orb-vault}"

SYSTEM_PROMPT_FILE="${SCRIPT_DIR}/prompts/subagent-system.md"
BLACKLIST_FILE="${REPO_ROOT}/sourcing/SOURCING-BLACKLIST.md"
WHITELIST_FILE="${REPO_ROOT}/sourcing/SOURCING-WHITELIST.md"
EXCERPT_SKILL_FILE="${REPO_ROOT}/.claude/skills/excerpt-text/SKILL.md"
RESULT_SCHEMA_VERSION=1

source "${SCRIPT_DIR}/lib/config.sh" 2>/dev/null || true
STATUS_DIR="${STATUS_DIR:-$(get_config status_dir /tmp/troothfairy-status 2>/dev/null || echo /tmp/troothfairy-status)}"
mkdir -p "$STATUS_DIR"
rm -f "${STATUS_DIR}"/active-*

vtk() { TICKETS_DIR="${VAULT_DIR}/.tickets" tk "$@"; }

if [[ ! -f "$SYSTEM_PROMPT_FILE" ]]; then
    echo "orchestrator: system prompt not found: $SYSTEM_PROMPT_FILE" >&2
    exit 1
fi
if [[ ! -d "$VAULT_DIR" ]]; then
    echo "orchestrator: vault directory not found: $VAULT_DIR" >&2
    exit 1
fi

BLACKLIST_CONTENT=""
if [[ -f "$BLACKLIST_FILE" ]]; then
    BLACKLIST_CONTENT=$(cat "$BLACKLIST_FILE")
fi

WHITELIST_CONTENT=""
if [[ -f "$WHITELIST_FILE" ]]; then
    WHITELIST_CONTENT=$(cat "$WHITELIST_FILE")
fi

DIRS_PROMPT_SECTION=""
while IFS=' ' read -r dir_path dir_access; do
    [[ -z "$dir_path" ]] && continue
    case "$dir_access" in
        read) access_label="read-only" ;;
        write) access_label="write-only" ;;
        read-write|rw) access_label="read-write" ;;
        *) access_label="${dir_access:-read-only}" ;;
    esac
    DIRS_PROMPT_SECTION+="- ${dir_path} [${access_label}]"$'\n'
done < <(get_dirs 2>/dev/null || true)

RAW_SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE")
SYSTEM_PROMPT="${RAW_SYSTEM_PROMPT//'[blacklist will be injected at runtime]'/$BLACKLIST_CONTENT}"
SYSTEM_PROMPT="${SYSTEM_PROMPT//'[whitelist will be injected at runtime]'/$WHITELIST_CONTENT}"

RESULT_SCHEMA_TEXT=$(cat <<EOF
{
  "schema_version": ${RESULT_SCHEMA_VERSION},
  "job_id": "ticket-id",
  "tag": "∆",
  "outcome": "success | no_op_success | corrected | degraded",
  "completion_tag": "º",
  "append_failure_marker": false,
  "response_lines": [
    "- #Ω∆ Main response",
    "\t- #¬ https://example.com — source description"
  ]
}
EOF
)

extract_json_payload() {
    awk '
    /^[[:space:]]*\{/ { capture=1 }
    capture { print }
    ' <<< "$1"
}

route_tools() {
    case "$1" in
        local-agent) printf 'Read,Write,Bash\n' ;;
        api-search) printf 'WebSearch,WebFetch\n' ;;
        *) printf '\n' ;;
    esac
}

route_name() {
    case "$1" in
        local-agent) printf 'Local Agent\n' ;;
        api-search) printf 'API Search\n' ;;
        hybrid) printf 'Hybrid\n' ;;
        *) printf 'Unknown\n' ;;
    esac
}

default_model_for_tag() {
    case "$1" in
        '$') printf 'haiku\n' ;;
        *) printf 'sonnet\n' ;;
    esac
}

apply_model_override() {
    local model="$1"
    local block_content="$2"
    if printf '%s\n' "$block_content" | grep -qiF '#opus'; then
        printf 'opus\n'
    elif printf '%s\n' "$block_content" | grep -qiF '#sonnet'; then
        printf 'sonnet\n'
    elif printf '%s\n' "$block_content" | grep -qiF '#haiku'; then
        printf 'haiku\n'
    else
        printf '%s\n' "$model"
    fi
}

tag_preview() {
    printf '%s' "$1" | sed 's/^[[:space:]]*-*[[:space:]]*#[^[:space:]]* //'
}

infer_child_indent() {
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

find_target_line() {
    local file_path="$1"
    local expected_line="$2"
    local tagged_line="$3"

    local current_line
    current_line=$(sed -n "${expected_line}p" "$file_path" 2>/dev/null)
    if [[ "$current_line" == "$tagged_line" ]]; then
        printf '%s\n' "$expected_line"
        return 0
    fi

    awk -v target="$tagged_line" '
    $0 == target { print NR; exit }
    ' "$file_path"
}

apply_result_to_file() {
    local file_path="$1"
    local job_file="$2"
    local result_file="$3"
    local expected_line="$4"

    local tagged_line tag_char block_content completion_tag append_failure_marker
    local target_line replaced_line indent_unit child_prefix
    local tmp_file line_no inserted_count response_count

    tagged_line=$(jq -r '.tagged_line' "$job_file")
    tag_char=$(jq -r '.tag_char' "$job_file")
    block_content=$(jq -r '.block_content' "$job_file")
    completion_tag=$(jq -r '.completion_tag' "$result_file")
    append_failure_marker=$(jq -r '.append_failure_marker' "$result_file")

    target_line=$(find_target_line "$file_path" "$expected_line" "$tagged_line")
    if [[ -z "$target_line" ]]; then
        echo "could not locate tagged line in ${file_path}" >&2
        return 1
    fi

    replaced_line=$(printf '%s\n' "$tagged_line" | perl -CSDA -e '
        use utf8;
        my ($tag_token, $completion_token) = @ARGV;
        local $/;
        my $text = <STDIN>;
        $text =~ s/\Q$tag_token\E/$completion_token/;
        print $text;
    ' "#${tag_char}" "#${completion_tag}")
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
    indent_unit=$(infer_child_indent "$tagged_line" "$block_content")
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

record_history() {
    local job_file="$1"
    local success_marker="$2"
    local timestamp preview tag_char vault_rel

    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    preview=$(tag_preview "$(jq -r '.tagged_line' "$job_file")")
    tag_char=$(jq -r '.tag_char' "$job_file")
    vault_rel=$(jq -r '.vault_rel' "$job_file")
    if [[ ${#preview} -gt 60 ]]; then
        preview="${preview:0:57}..."
    fi
    printf '%s %s #%s %s\t%s\n' "$timestamp" "$success_marker" "$tag_char" "$preview" "$vault_rel" >> "${STATUS_DIR}/history.log"
}

TICKET_IDS=$(vtk list --status=open --tags=troothfairy 2>/dev/null | awk '{print $1}' | grep -E '^[a-zA-Z0-9_-]+$' || true)

if [[ -z "$TICKET_IDS" ]]; then
    echo "orchestrator: no open troothfairy tickets. Nothing to do."
    exit 0
fi

echo "orchestrator: found tickets:"
echo "$TICKET_IDS"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

declare -a PIDS=()
declare -a TICKET_ID_ARRAY=()
declare -a JOB_FILES=()
declare -a RESULT_FILES=()
declare -a STATUS_FILES=()
declare -a ACTIVE_FILES=()

overall_exit=0

while IFS= read -r ticket_id; do
    [[ -z "$ticket_id" ]] && continue

    ticket_body=$(vtk show "$ticket_id" 2>/dev/null) || {
        echo "orchestrator: could not fetch ticket $ticket_id, skipping" >&2
        continue
    }

    job_json=$(extract_json_payload "$ticket_body")
    if [[ -z "$job_json" ]] || ! printf '%s\n' "$job_json" | jq -e '.schema_version == 1' >/dev/null 2>&1; then
        vtk add-note "$ticket_id" "Failed: unsupported or missing block-job payload"
        overall_exit=1
        continue
    fi

    job_file="${WORK_DIR}/${ticket_id}.job.json"
    printf '%s\n' "$job_json" > "$job_file"

    file_path=$(jq -r '.file_path' "$job_file")
    file_basename=$(jq -r '.file_basename' "$job_file")
    line_number=$(jq -r '.line_number' "$job_file")
    tag_char=$(jq -r '.tag_char' "$job_file")
    tag_label=$(jq -r '.tag_label' "$job_file")
    route=$(jq -r '.route' "$job_file")
    tagged_line=$(jq -r '.tagged_line' "$job_file")
    block_content=$(jq -r '.block_content' "$job_file")
    needs_full_file=$(jq -r '.needs_full_file' "$job_file")
    vault_rel=$(jq -r '.vault_rel' "$job_file")

    if [[ ! -f "$file_path" ]]; then
        vtk add-note "$ticket_id" "Failed: source file not found: $file_path"
        overall_exit=1
        continue
    fi

    if [[ "$route" == "hybrid" ]]; then
        vtk add-note "$ticket_id" "Failed: hybrid route is intentionally disabled"
        overall_exit=1
        continue
    fi

    subagent_model=$(default_model_for_tag "$tag_char")
    subagent_model=$(apply_model_override "$subagent_model" "$block_content")
    subagent_tools=$(route_tools "$route")

    active_desc="#${tag_char} $(tag_preview "$tagged_line")"$'\t'"${vault_rel}"
    printf '%s\n' "$active_desc" > "${STATUS_DIR}/active-${ticket_id}"

    prompt_file="${WORK_DIR}/${ticket_id}.prompt"
    system_prompt_file="${WORK_DIR}/${ticket_id}.system"
    result_file="${WORK_DIR}/${ticket_id}.result.json"
    status_file="${WORK_DIR}/${ticket_id}.status"

    user_prompt="Process one Obsidian tagged block and return JSON only.

Ticket ID: ${ticket_id}
Route: ${route} ($(route_name "$route"))
File: ${file_path}
Line number: ${line_number}
Tag: #${tag_char} (${tag_label})

Exact tagged line:
\`\`\`
${tagged_line}
\`\`\`

Block content:
\`\`\`
${block_content}
\`\`\`
"

    if [[ "$needs_full_file" == "true" ]]; then
        file_content=$(cat "$file_path")
        user_prompt+="
Full file content:
\`\`\`
${file_content}
\`\`\`
"
    fi

    if [[ "$route" == "local-agent" ]] && [[ -n "$DIRS_PROMPT_SECTION" ]]; then
        user_prompt+="
Configured directories:
${DIRS_PROMPT_SECTION}
"
    fi

    user_prompt+="
Return ONLY valid JSON matching this schema:
\`\`\`json
${RESULT_SCHEMA_TEXT}
\`\`\`

Rules:
- Do not edit the vault file directly.
- response_lines must be an array of relative bullet lines. The first inserted line should usually start with - #Ω${tag_char} unless the correct output is a no-op success.
- For nested children under your first bullet, use leading tabs in response_lines.
- For #©, use outcome: no_op_success with an empty response_lines array when the assertion is correct.
- Use append_failure_marker: true for degraded outcomes.
- Do not wrap the JSON in markdown fences.
"

    printf '%s' "$user_prompt" > "$prompt_file"
    printf '%s' "$SYSTEM_PROMPT" > "$system_prompt_file"
    if [[ "$tag_char" == '$' ]] && [[ -f "$EXCERPT_SKILL_FILE" ]]; then
        printf '\n\n---\n\n## Skill: excerpt-text\n\n%s' "$(cat "$EXCERPT_SKILL_FILE")" >> "$system_prompt_file"
    fi

    _model="$subagent_model"
    _tools="$subagent_tools"
    (
        stdout_file="${WORK_DIR}/${ticket_id}.stdout"
        stderr_file="${WORK_DIR}/${ticket_id}.stderr"

        if claude \
            --model "$_model" \
            -p "$(cat "$prompt_file")" \
            --system-prompt "$(cat "$system_prompt_file")" \
            --allowedTools "$_tools" \
            >"$stdout_file" 2>"$stderr_file"; then
            result_json=$(extract_json_payload "$(cat "$stdout_file")")
            if [[ -z "$result_json" ]]; then
                printf '1 invalid_json no-json-object-returned' > "$status_file"
                exit 0
            fi
            if printf '%s\n' "$result_json" | jq -e '
                .schema_version == 1 and
                (.job_id | type == "string") and
                (.tag | type == "string") and
                (.outcome | type == "string") and
                (.completion_tag | type == "string") and
                (.append_failure_marker | type == "boolean") and
                (.response_lines | type == "array")
            ' >/dev/null 2>&1; then
                printf '%s\n' "$result_json" > "$result_file"
                printf '0' > "$status_file"
            else
                printf '1 invalid_json schema-validation-failed' > "$status_file"
            fi
        else
            exit_code=$?
            stderr_content=$(head -5 "$stderr_file" 2>/dev/null | tr '\n' ' ')
            printf '1 claude_failed exit_code=%s %s' "$exit_code" "$stderr_content" > "$status_file"
        fi
    ) &

    PIDS+=("$!")
    TICKET_ID_ARRAY+=("$ticket_id")
    JOB_FILES+=("$job_file")
    RESULT_FILES+=("$result_file")
    STATUS_FILES+=("$status_file")
    ACTIVE_FILES+=("${STATUS_DIR}/active-${ticket_id}")

    echo "orchestrator: launched worker for ticket $ticket_id (route: $route, file: $file_basename, pid: $!)"
done <<< "$TICKET_IDS"

if [[ ${#PIDS[@]} -eq 0 ]]; then
    echo "orchestrator: no workers were launched."
    exit $overall_exit
fi

echo "orchestrator: waiting for ${#PIDS[@]} worker(s) to finish..."

declare -a SUCCESS_RECORDS=()

for i in "${!PIDS[@]}"; do
    pid="${PIDS[$i]}"
    ticket_id="${TICKET_ID_ARRAY[$i]}"
    job_file="${JOB_FILES[$i]}"
    result_file="${RESULT_FILES[$i]}"
    status_file="${STATUS_FILES[$i]}"
    active_file="${ACTIVE_FILES[$i]}"

    wait "$pid" 2>/dev/null || true
    rm -f "$active_file"

    status_content=""
    if [[ -f "$status_file" ]]; then
        status_content=$(cat "$status_file")
    fi

    if [[ "$status_content" == "0" ]]; then
        SUCCESS_RECORDS+=("${ticket_id}"$'\t'"${job_file}"$'\t'"${result_file}")
    else
        error_detail="${status_content#1 }"
        [[ -n "$error_detail" ]] || error_detail="worker failed before producing a result"
        vtk add-note "$ticket_id" "Failed: ${error_detail}" 2>/dev/null || true
        record_history "$job_file" "✗"
        overall_exit=1
    fi
done

SUCCESS_MANIFEST="${WORK_DIR}/success.manifest"
: > "$SUCCESS_MANIFEST"
if [[ ${#SUCCESS_RECORDS[@]} -gt 0 ]]; then
    printf '%s\n' "${SUCCESS_RECORDS[@]}" > "$SUCCESS_MANIFEST"
fi

if [[ -s "$SUCCESS_MANIFEST" ]]; then
    FILE_MANIFEST="${WORK_DIR}/files.manifest"
    while IFS=$'\t' read -r _ticket_id job_file _result_file; do
        [[ -n "$job_file" ]] || continue
        jq -r '.file_path' "$job_file"
    done < "$SUCCESS_MANIFEST" | sort -u > "$FILE_MANIFEST"

    while IFS= read -r file_path; do
        [[ -n "$file_path" ]] || continue
        queue_file="${WORK_DIR}/queue-$(printf '%s' "$file_path" | shasum -a 256 | cut -c1-16).tsv"
        : > "$queue_file"

        while IFS=$'\t' read -r ticket_id job_file result_file; do
            [[ -n "$job_file" ]] || continue
            job_file_path=$(jq -r '.file_path' "$job_file")
            if [[ "$job_file_path" == "$file_path" ]]; then
                line_number=$(jq -r '.line_number' "$job_file")
                printf '%s\t%s\t%s\t%s\n' "$line_number" "$ticket_id" "$job_file" "$result_file" >> "$queue_file"
            fi
        done < "$SUCCESS_MANIFEST"

        offset=0
        sorted_queue="${queue_file}.sorted"
        sort -n "$queue_file" > "$sorted_queue"
        while IFS=$'\t' read -r line_number ticket_id job_file result_file; do
            effective_line=$((line_number + offset))
            inserted_count=$(apply_result_to_file "$file_path" "$job_file" "$result_file" "$effective_line")
            apply_exit=$?
            if [[ "$apply_exit" -eq 0 ]]; then
                offset=$((offset + inserted_count))
                if vtk close "$ticket_id" 2>/dev/null; then
                    record_history "$job_file" "✓"
                    echo "orchestrator: ticket $ticket_id closed (patched successfully)"
                else
                    vtk add-note "$ticket_id" "Failed: patch applied but ticket could not be closed" 2>/dev/null || true
                    overall_exit=1
                fi
            else
                vtk add-note "$ticket_id" "Failed: deterministic patch application failed" 2>/dev/null || true
                record_history "$job_file" "✗"
                overall_exit=1
            fi
        done < "$sorted_queue"
    done < "$FILE_MANIFEST"
fi

echo "orchestrator: done."
exit $overall_exit
