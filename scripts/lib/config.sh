#!/usr/bin/env bash
# config.sh — shared config reader for Troothfairy scripts
#
# Sources this file to get config helpers.
# Reads flat key/value settings and simple list blocks from config.yaml.

resolve_repo_root() {
    if [[ -n "${CONFIG_FILE:-}" ]]; then
        local config_dir
        config_dir="$(cd "$(dirname "$CONFIG_FILE")" 2>/dev/null && pwd)" || return 1
        printf '%s' "$config_dir"
        return 0
    fi

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

resolve_config_file() {
    if [[ -n "${CONFIG_FILE:-}" ]]; then
        printf '%s' "$CONFIG_FILE"
        return 0
    fi

    local repo_root
    repo_root="$(resolve_repo_root)" || return 1
    printf '%s/config.yaml' "$repo_root"
}

resolve_config_path() {
    local path="$1"
    local repo_root
    repo_root="$(resolve_repo_root)" || return 1

    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        path="${path#./}"
        printf '%s/%s\n' "$repo_root" "$path" | sed 's#/\./#/#g'
    fi
}

# get_config <key> [default]
# Reads a flat key from config.yaml. Strips inline comments.
get_config() {
    local key="$1"
    local default="${2:-}"
    local config_file
    config_file="$(resolve_config_file)" || { printf '%s' "$default"; return; }
    if [[ ! -f "$config_file" ]]; then
        printf '%s' "$default"
        return
    fi
    local val
    val=$(grep "^${key}:" "$config_file" 2>/dev/null | head -1 | sed "s/^${key}:[[:space:]]*//" | sed 's/[[:space:]]*#.*//')
    printf '%s' "${val:-$default}"
}

get_config_list() {
    local key="$1"
    local config_file
    config_file="$(resolve_config_file)" || return 0
    [[ -f "$config_file" ]] || return 0

    awk -v key="$key" '
    $0 ~ "^" key ":" { in_list=1; next }
    in_list && /^[^[:space:]]/ { in_list=0 }
    in_list && /^[[:space:]]*-[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", line)
        sub(/[[:space:]]*#.*$/, "", line)
        if (length(line) > 0) print line
    }
    ' "$config_file"
}

# get_dirs — print configured directory entries, one per line as "absolute_path access"
# Parses the dirs: list block from config.yaml.
# Relative paths resolve against the repo root, except write targets under
# `./_EXCERPTS`, which resolve against the active vault path.
get_dirs() {
    local active_vault_root="${1:-}"
    local repo_root config_file
    repo_root="$(resolve_repo_root)" || return 0
    config_file="$(resolve_config_file)" || return 0
    [[ -f "$config_file" ]] || return 0
    local vault_root
    if [[ -n "$active_vault_root" ]]; then
        vault_root="$active_vault_root"
    else
        vault_root="$(resolve_vault_path 2>/dev/null)" || vault_root=""
    fi
    awk -v repo_root="$repo_root" -v vault_root="$vault_root" '
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
        if (substr(path, 1, 1) != "/") {
            sub(/^\.\//, "", path)
            if (vault_root != "" && path ~ /^_EXCERPTS(\/|$)/) {
                path = vault_root "/" path
            } else {
                path = repo_root "/" path
            }
        }
        print path " " access
    }
    ' "$config_file"
}

resolve_vault_paths() {
    local configured="" candidate resolved

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        resolved="$(resolve_config_path "$candidate")" || continue
        if [[ -z "$configured" ]]; then
            configured="$resolved"
        elif ! printf '%s\n' "$configured" | grep -Fxq "$resolved"; then
            configured="${configured}"$'\n'"${resolved}"
        fi
    done < <(get_config_list vaults)

    if [[ -z "$configured" ]]; then
        candidate="$(get_config vault_path ./orb-vault)"
        resolved="$(resolve_config_path "$candidate")" || return 1
        configured="$resolved"
    fi

    printf '%s\n' "$configured"
}

# resolve_vault_path — returns the first absolute vault path from config
resolve_vault_path() {
    resolve_vault_paths | head -1
}
