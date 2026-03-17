#!/usr/bin/env bash
# config.sh — shared config reader for Troothfairy scripts
#
# Sources this file to get get_config() and resolve_repo_root().
# Reads flat key: value pairs from config.yaml at the repo root.

resolve_repo_root() {
    local dir="${BASH_SOURCE[1]:-$0}"
    dir="$(cd "$(dirname "$dir")" && pwd)"
    # Walk up until we find config.yaml
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/config.yaml" ]]; then
            printf '%s' "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# get_config <key> [default]
# Reads a flat key from config.yaml. Strips inline comments.
get_config() {
    local key="$1"
    local default="${2:-}"
    local repo_root
    repo_root="$(resolve_repo_root)" || { printf '%s' "$default"; return; }
    local config_file="${repo_root}/config.yaml"
    if [[ ! -f "$config_file" ]]; then
        printf '%s' "$default"
        return
    fi
    local val
    val=$(grep "^${key}:" "$config_file" 2>/dev/null | head -1 | sed "s/^${key}:[[:space:]]*//" | sed 's/[[:space:]]*#.*//')
    printf '%s' "${val:-$default}"
}

# get_dirs — print configured directory entries, one per line as "absolute_path access"
# Parses the dirs: list block from config.yaml; resolves relative paths against repo root.
get_dirs() {
    local repo_root
    repo_root="$(resolve_repo_root)" || return 0
    local config_file="${repo_root}/config.yaml"
    [[ -f "$config_file" ]] || return 0
    awk -v repo_root="$repo_root" '
    /^dirs:/              { in_dirs=1; next }
    in_dirs && /^[^[:space:]]/ { in_dirs=0 }
    in_dirs && /^[[:space:]]*-[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        sub(/[[:space:]]*#.*$/, "", line)
        if (length(line) == 0) next
        n = split(line, parts, /[[:space:]]+/)
        path   = parts[1]
        access = (n >= 2) ? parts[2] : "read"
        if (substr(path, 1, 1) != "/") path = repo_root "/" path
        print path " " access
    }
    ' "$config_file"
}

# resolve_vault_path — returns absolute vault path from config
resolve_vault_path() {
    local vault_path
    vault_path="$(get_config vault_path ./orb-vault)"
    local repo_root
    repo_root="$(resolve_repo_root)" || return 1
    if [[ "$vault_path" == /* ]]; then
        printf '%s' "$vault_path"
    else
        printf '%s' "${repo_root}/${vault_path}"
    fi
}
