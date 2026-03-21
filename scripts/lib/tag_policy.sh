#!/usr/bin/env bash
# tag_policy.sh — structured tag/route policy helpers

TAG_POLICY_FILE_DEFAULT="config/tag_policy.json"
BLOCK_JOB_SCHEMA_FILE_DEFAULT="config/block-job-schema.json"
RESULT_SCHEMA_FILE_DEFAULT="config/result-schema.json"

resolve_tag_policy_file() {
    local repo_root
    local path="${TAG_POLICY_FILE:-$TAG_POLICY_FILE_DEFAULT}"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    repo_root="$(resolve_repo_root)" || return 1
    printf '%s/%s\n' "$repo_root" "$path"
}

resolve_block_job_schema_file() {
    local repo_root
    local path="${BLOCK_JOB_SCHEMA_FILE:-$BLOCK_JOB_SCHEMA_FILE_DEFAULT}"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    repo_root="$(resolve_repo_root)" || return 1
    printf '%s/%s\n' "$repo_root" "$path"
}

resolve_result_schema_file() {
    local repo_root
    local path="${RESULT_SCHEMA_FILE:-$RESULT_SCHEMA_FILE_DEFAULT}"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    repo_root="$(resolve_repo_root)" || return 1
    printf '%s/%s\n' "$repo_root" "$path"
}

policy_jq() {
    local policy_file
    policy_file="$(resolve_tag_policy_file)" || return 1
    jq -r "$@" "$policy_file"
}

block_job_schema_version() {
    jq -r '.schema_version' "$(resolve_block_job_schema_file)"
}

result_schema_version() {
    jq -r '.schema_version' "$(resolve_result_schema_file)"
}

policy_tag_chars() {
    policy_jq '.tags | keys[]'
}

policy_tag_label() { policy_jq --arg tag "$1" '.tags[$tag].label'; }
policy_tag_meaning() { policy_jq --arg tag "$1" '.tags[$tag].meaning'; }
policy_tag_route() { policy_jq --arg tag "$1" '.tags[$tag].route'; }
policy_tag_needs_full_file() { policy_jq --arg tag "$1" '.tags[$tag].needs_full_file'; }
policy_tag_allow_empty_response() { policy_jq --arg tag "$1" '.tags[$tag].allow_empty_response'; }
policy_tag_default_model() { policy_jq --arg tag "$1" '.tags[$tag].default_model'; }
policy_tag_completion() { policy_jq --arg tag "$1" --arg outcome "$2" '.tags[$tag].completion[$outcome] // empty'; }

policy_route_display_name() { policy_jq --arg route "$1" '.routes[$route].display_name'; }
policy_route_enabled() { policy_jq --arg route "$1" '.routes[$route].enabled'; }
policy_route_disabled_reason() { policy_jq --arg route "$1" '.routes[$route].disabled_reason // empty'; }
policy_route_tools() { policy_jq --arg route "$1" '.routes[$route].allowed_tools | join(",")'; }

policy_route_capability_section() {
    policy_jq --arg route "$1" '
      .routes[$route] as $route_cfg |
      "Route capabilities:\nAllowed:\n"
      + (($route_cfg.allow_capabilities // []) | map("- " + .) | join("\n"))
      + "\nForbidden:\n"
      + (($route_cfg.deny_capabilities // []) | map("- " + .) | join("\n"))
    '
}

policy_tag_section() {
    policy_jq '
      .tags
      | to_entries
      | map("### `#" + .key + "` — " + .value.label + "\n"
          + .value.meaning + "\n"
          + "- route: `" + .value.route + "`\n"
          + "- default model: `" + .value.default_model + "`\n"
          + "- needs full file: `" + (.value.needs_full_file|tostring) + "`\n"
          + "- empty response allowed: `" + (.value.allow_empty_response|tostring) + "`\n")
      | join("\n")
    '
}

render_template() {
    local template_path="$1"
    perl -0pe 's/\{\{([A-Z0-9_]+)\}\}/exists $ENV{$1} ? $ENV{$1} : $&/ge' "$template_path"
}

validate_block_job_payload_file() {
    local payload_file="$1"
    local expected_version
    expected_version="$(block_job_schema_version)"
    jq -e --argjson expected_version "$expected_version" '
        .schema_version == $expected_version and
        (.file_path | type == "string") and
        (.vault_rel | type == "string") and
        (.file_basename | type == "string") and
        (.line_number | type == "number") and
        (.tag_char | type == "string") and
        (.tag_label | type == "string") and
        (.route | type == "string") and
        (.needs_full_file | type == "boolean") and
        (.tagged_line | type == "string") and
        (.block_content | type == "string")
    ' "$payload_file"
}

validate_result_payload_file() {
    local payload_file="$1"
    local expected_version
    expected_version="$(result_schema_version)"
    jq -e --argjson expected_version "$expected_version" '
        .schema_version == $expected_version and
        (.job_id | type == "string") and
        (.tag | type == "string") and
        (.outcome | type == "string") and
        (.completion_tag | type == "string") and
        (.append_failure_marker | type == "boolean") and
        (.response_lines | type == "array")
    ' "$payload_file"
}
