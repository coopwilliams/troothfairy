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

SYSTEM_TEMPLATE_FILE="${SCRIPT_DIR}/prompts/system.tmpl.md"
JOB_TEMPLATE_FILE="${SCRIPT_DIR}/prompts/job.tmpl.md"
BLACKLIST_FILE="${REPO_ROOT}/sourcing/SOURCING-BLACKLIST.md"
WHITELIST_FILE="${REPO_ROOT}/sourcing/SOURCING-WHITELIST.md"
EXCERPT_SKILL_FILE="${REPO_ROOT}/.claude/skills/excerpt-text/SKILL.md"

source "${SCRIPT_DIR}/lib/config.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/lib/tag_policy.sh" 2>/dev/null || true
source "${SCRIPT_DIR}/patch_engine.sh" 2>/dev/null || true
STATUS_DIR="${STATUS_DIR:-$(get_config status_dir /tmp/troothfairy-status 2>/dev/null || echo /tmp/troothfairy-status)}"
mkdir -p "$STATUS_DIR"
rm -f "${STATUS_DIR}"/active-*

vtk() { TICKETS_DIR="${VAULT_DIR}/.tickets" tk "$@"; }

if [[ ! -f "$SYSTEM_TEMPLATE_FILE" ]]; then
    echo "orchestrator: system prompt template not found: $SYSTEM_TEMPLATE_FILE" >&2
    exit 1
fi
if [[ ! -f "$JOB_TEMPLATE_FILE" ]]; then
    echo "orchestrator: job prompt template not found: $JOB_TEMPLATE_FILE" >&2
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
done < <(get_dirs "$VAULT_DIR" 2>/dev/null || true)

BLOCK_JOB_SCHEMA_VERSION="$(block_job_schema_version)"
RESULT_SCHEMA_FILE="$(resolve_result_schema_file)"
RESULT_SCHEMA_VERSION="$(result_schema_version)"
RESULT_SCHEMA_TEXT=$(cat "$RESULT_SCHEMA_FILE")

extract_json_payload() {
    perl -CSDA -0ne '
        if (/```(?:json)?\s*(.*?)\s*```/s) {
            print $1;
            exit;
        }
        if (/(\{(?:(?>[^{}]+)|(?1))*\})/s) {
            print $1;
            exit;
        }
    ' <<< "$1"
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

completion_tag_for_tag() {
    local completion
    completion=$(policy_tag_completion "$1" degraded)
    if [[ -n "$completion" ]]; then
        printf '%s\n' "$completion"
    else
        printf 'º\n'
    fi
}

build_degraded_result() {
    local ticket_id="$1"
    local job_file="$2"
    local result_file="$3"
    local error_detail="$4"

    local tag_char completion_tag degraded_text
    tag_char=$(jq -r '.tag_char' "$job_file")
    completion_tag=$(completion_tag_for_tag "$tag_char")

    case "$error_detail" in
        invalid_json*)
            degraded_text="The agent returned an invalid structured result. Troothfairy marked this block as degraded."
            ;;
        claude_failed*)
            degraded_text="The agent failed before returning a structured result. Troothfairy marked this block as degraded."
            ;;
        *)
            degraded_text="Troothfairy could not complete this block reliably and marked it as degraded."
            ;;
    esac

    jq -n \
        --argjson schema_version "$RESULT_SCHEMA_VERSION" \
        --arg job_id "$ticket_id" \
        --arg tag "$tag_char" \
        --arg completion_tag "$completion_tag" \
        --arg response_line "- #Ω${tag_char} ${degraded_text}" \
        '{
            schema_version: $schema_version,
            job_id: $job_id,
            tag: $tag,
            outcome: "degraded",
            completion_tag: $completion_tag,
            append_failure_marker: true,
            response_lines: [$response_line]
        }' > "$result_file"
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
declare -a RESULT_MARKERS=()

overall_exit=0

while IFS= read -r ticket_id; do
    [[ -z "$ticket_id" ]] && continue

    ticket_body=$(vtk show "$ticket_id" 2>/dev/null) || {
        echo "orchestrator: could not fetch ticket $ticket_id, skipping" >&2
        continue
    }

    job_json=$(extract_json_payload "$ticket_body")
    if [[ -z "$job_json" ]]; then
        vtk add-note "$ticket_id" "Failed: missing block-job payload"
        overall_exit=1
        continue
    fi

    job_file="${WORK_DIR}/${ticket_id}.job.json"
    printf '%s\n' "$job_json" > "$job_file"

    actual_job_schema_version=$(jq -r '.schema_version // "missing"' "$job_file" 2>/dev/null || printf 'missing\n')
    if ! validate_block_job_payload_file "$job_file" >/dev/null 2>&1; then
        if [[ "$actual_job_schema_version" != "$BLOCK_JOB_SCHEMA_VERSION" ]]; then
            vtk add-note "$ticket_id" "Failed: unsupported block-job schema version ${actual_job_schema_version} (expected ${BLOCK_JOB_SCHEMA_VERSION})"
        else
            vtk add-note "$ticket_id" "Failed: invalid block-job payload"
        fi
        overall_exit=1
        continue
    fi

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

    route_enabled=$(policy_route_enabled "$route")
    if [[ "$route_enabled" != "true" ]]; then
        vtk add-note "$ticket_id" "Failed: $(policy_route_disabled_reason "$route")"
        overall_exit=1
        continue
    fi

    subagent_model=$(policy_tag_default_model "$tag_char")
    subagent_model=$(apply_model_override "$subagent_model" "$block_content")
    subagent_tools=$(policy_route_tools "$route")
    route_display_name=$(policy_route_display_name "$route")

    active_desc="#${tag_char} $(tag_preview "$tagged_line")"$'\t'"${vault_rel}"
    printf '%s\n' "$active_desc" > "${STATUS_DIR}/active-${ticket_id}"

    prompt_file="${WORK_DIR}/${ticket_id}.prompt"
    system_prompt_file="${WORK_DIR}/${ticket_id}.system"
    result_file="${WORK_DIR}/${ticket_id}.result.json"
    status_file="${WORK_DIR}/${ticket_id}.status"

    FULL_FILE_SECTION=""
    if [[ "$needs_full_file" == "true" ]]; then
        file_content=$(cat "$file_path")
        FULL_FILE_SECTION=$'Full file content:\n```\n'"${file_content}"$'\n```\n\n'
    fi

    DIRS_SECTION=""
    if [[ "$route" == "local-agent" ]] && [[ -n "$DIRS_PROMPT_SECTION" ]]; then
        DIRS_SECTION=$'Configured directories:\n'"${DIRS_PROMPT_SECTION}"$'\n'
    fi

    export TICKET_ID="$ticket_id"
    export ROUTE_NAME="$route_display_name"
    export ROUTE_ID="$route"
    export FILE_PATH="$file_path"
    export LINE_NUMBER="$line_number"
    export TAG_CHAR="$tag_char"
    export TAG_LABEL="$tag_label"
    export TAGGED_LINE="$tagged_line"
    export BLOCK_CONTENT="$block_content"
    export FULL_FILE_SECTION="$FULL_FILE_SECTION"
    export DIRS_SECTION="$DIRS_SECTION"
    export RESULT_SCHEMA_TEXT="$RESULT_SCHEMA_TEXT"
    render_template "$JOB_TEMPLATE_FILE" > "$prompt_file"

    export BLACKLIST_CONTENT="$BLACKLIST_CONTENT"
    export WHITELIST_CONTENT="$WHITELIST_CONTENT"
    export ROUTE_CAPABILITY_SECTION="$(policy_route_capability_section "$route")"
    export TAG_POLICY_SECTION="$(policy_tag_section)"
    render_template "$SYSTEM_TEMPLATE_FILE" > "$system_prompt_file"
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
            printf '%s\n' "$result_json" > "$result_file"
            actual_result_schema_version=$(jq -r '.schema_version // "missing"' "$result_file" 2>/dev/null || printf 'missing\n')
            if validate_result_payload_file "$result_file" >/dev/null 2>&1 && jq -e --arg ticket_id "$ticket_id" --arg tag "$tag_char" '
                .job_id == $ticket_id and .tag == $tag
            ' "$result_file" >/dev/null 2>&1; then
                printf '0' > "$status_file"
            else
                if [[ "$actual_result_schema_version" != "$RESULT_SCHEMA_VERSION" ]]; then
                    printf '1 invalid_json unsupported-result-schema-version=%s expected=%s' "$actual_result_schema_version" "$RESULT_SCHEMA_VERSION" > "$status_file"
                else
                    printf '1 invalid_json schema-validation-failed' > "$status_file"
                fi
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
    RESULT_MARKERS+=("pending")

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
        RESULT_MARKERS[$i]="success"
    else
        error_detail="${status_content#1 }"
        [[ -n "$error_detail" ]] || error_detail="worker failed before producing a result"
        build_degraded_result "$ticket_id" "$job_file" "$result_file" "$error_detail"
        printf '%s\n' "Degraded: ${error_detail}" > "${WORK_DIR}/${ticket_id}.note"
        SUCCESS_RECORDS+=("${ticket_id}"$'\t'"${job_file}"$'\t'"${result_file}")
        RESULT_MARKERS[$i]="degraded"
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
            inserted_count=$(patch_engine_apply_intent "$file_path" "$job_file" "$result_file" "$effective_line")
            apply_exit=$?
            if [[ "$apply_exit" -eq 0 ]]; then
                offset=$((offset + inserted_count))
                note_file="${WORK_DIR}/${ticket_id}.note"
                if [[ -f "$note_file" ]]; then
                    vtk add-note "$ticket_id" "$(cat "$note_file")" 2>/dev/null || true
                fi
                if vtk close "$ticket_id" 2>/dev/null; then
                    if [[ -f "$note_file" ]]; then
                        record_history "$job_file" "✗"
                    else
                        record_history "$job_file" "✓"
                    fi
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
