#!/bin/bash
# Module 11: Setup bashrc aliases
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Setting up bashrc aliases..."

BASHRC="$INSTALL_HOME/.bashrc"
MARKER="# >>> MyClaude >>>"

if ! grep -qF "$MARKER" "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<BASHEOF

# >>> MyClaude >>>
alias myclaude-start='sudo systemctl start myclaude'
alias myclaude-stop='sudo systemctl stop myclaude'
alias myclaude-status='sudo systemctl status myclaude'
alias myclaude-logs='journalctl -u myclaude -f'
# <<< MyClaude <<<
BASHEOF
    log_info "Aliases added to $BASHRC"
else
    log_info "Aliases already exist in $BASHRC"
fi