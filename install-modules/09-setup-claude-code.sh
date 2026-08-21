#!/bin/bash
# Module 09: Install Claude Code
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Installing Claude Code..."

if ! command -v claude &>/dev/null; then
    npm install -g @anthropic-ai/claude-code
else
    log_info "Claude Code already installed"
fi