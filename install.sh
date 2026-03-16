#!/usr/bin/env bash
# install.sh — One-command setup for Troothfairy
#
# Usage: ./install.sh
#
# Prerequisites: macOS with Homebrew and Claude Code CLI installed.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${REPO_ROOT}/scripts/lib/config.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "${GREEN}==>${NC} %s\n" "$*"; }
warn()  { printf "${YELLOW}==>${NC} %s\n" "$*"; }
fail()  { printf "${RED}==>${NC} %s\n" "$*"; exit 1; }

# ---------------------------------------------------------------------------
# 1. Check prerequisites
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

if ! command -v brew >/dev/null 2>&1; then
    fail "Homebrew is required. Install it from https://brew.sh"
fi

if ! command -v claude >/dev/null 2>&1; then
    fail "Claude Code CLI is required. Install it from https://claude.ai/claude-code"
fi

# ---------------------------------------------------------------------------
# 2. Install brew dependencies
# ---------------------------------------------------------------------------
install_if_missing() {
    local cmd="$1" pkg="$2" type="${3:-formula}"
    if command -v "$cmd" >/dev/null 2>&1; then
        info "$cmd already installed."
    else
        info "Installing $pkg..."
        if [[ "$type" == "cask" ]]; then
            brew install --cask "$pkg"
        else
            brew install "$pkg"
        fi
    fi
}

install_if_missing fswatch fswatch formula
install_if_missing tk ticket formula

# ticket requires a tap
if ! command -v tk >/dev/null 2>&1; then
    info "Adding wedow/tools tap for ticket..."
    brew tap wedow/tools
    brew install ticket
fi

# SwiftBar is a cask
if ! ls /Applications/SwiftBar.app >/dev/null 2>&1; then
    info "Installing SwiftBar..."
    brew install --cask swiftbar
else
    info "SwiftBar already installed."
fi

# ---------------------------------------------------------------------------
# 3. Set up SwiftBar plugin
# ---------------------------------------------------------------------------
PLUGIN_DIR="$HOME/Library/SwiftBar"
PLUGIN_SRC="${REPO_ROOT}/scripts/troothfairy.1s.sh"
PLUGIN_LINK="${PLUGIN_DIR}/troothfairy.1s.sh"

info "Setting up SwiftBar plugin directory..."
mkdir -p "$PLUGIN_DIR"

# Set SwiftBar's plugin directory preference
defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUGIN_DIR" 2>/dev/null || true

if [[ -L "$PLUGIN_LINK" ]]; then
    info "SwiftBar plugin symlink already exists."
elif [[ -f "$PLUGIN_LINK" ]]; then
    warn "A file (not symlink) exists at $PLUGIN_LINK — skipping. Remove it manually if you want to replace it."
else
    ln -s "$PLUGIN_SRC" "$PLUGIN_LINK"
    info "Symlinked SwiftBar plugin."
fi

# Make all scripts executable
chmod +x "${REPO_ROOT}"/scripts/*.sh
chmod +x "${REPO_ROOT}"/tests/*.sh

# ---------------------------------------------------------------------------
# 4. Create status directory
# ---------------------------------------------------------------------------
STATUS_DIR="$(get_config status_dir /tmp/troothfairy-status)"
mkdir -p "$STATUS_DIR"

# ---------------------------------------------------------------------------
# 5. Launch SwiftBar if not running
# ---------------------------------------------------------------------------
if ! pgrep -q SwiftBar; then
    info "Launching SwiftBar..."
    open -a SwiftBar
else
    info "SwiftBar is already running."
fi

# ---------------------------------------------------------------------------
# 6. Set up the vault
# ---------------------------------------------------------------------------
VAULT_PATH="$(resolve_vault_path)"
if [[ ! -d "$VAULT_PATH" ]]; then
    info "Creating vault directory at $VAULT_PATH..."
    mkdir -p "$VAULT_PATH"
fi

# ---------------------------------------------------------------------------
# 7. Start the daemon
# ---------------------------------------------------------------------------
WATCH_SH="${REPO_ROOT}/scripts/watch.sh"
if "$WATCH_SH" status >/dev/null 2>&1; then
    info "Troothfairy daemon is already running."
else
    info "Starting Troothfairy daemon..."
    "$WATCH_SH" start "$VAULT_PATH"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
printf "${BOLD}${GREEN}Troothfairy is installed and running!${NC}\n"
echo ""
echo "  Menu bar:  Look for the 🪄 icon"
echo "  Vault:     $VAULT_PATH"
echo "  Config:    ${REPO_ROOT}/config.yaml"
echo ""
echo "  Write notes in Obsidian with these tags:"
echo "    #ƒ  Explicit instruction for the agent"
echo "    #∆  Evaluate and enrich with context"
echo "    #∑  Evaluate with full file context"
echo "    #©  Fact-check (pass or correct)"
echo ""
echo "  Save the file and Troothfairy will process it automatically."
