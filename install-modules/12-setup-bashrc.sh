#!/bin/bash
# Module: 12-setup-bashrc
# Add bash aliases

run_12_setup_bashrc() {
    setup_bashrc
}

setup_bashrc() {
    log_info "Setting up bash aliases..."

    local bashrc="$HOME/.bashrc"
    local marker="# >>> MyClaude >>>"

    if ! grep -qF "$marker" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" <<'BASHEOF'

# >>> MyClaude >>>
alias myclaude-start='sudo systemctl start myclaude'
alias myclaude-stop='sudo systemctl stop myclaude'
alias myclaude-status='sudo systemctl status myclaude'
alias myclaude-logs='journalctl -u myclaude -f'
# <<< MyClaude <<<
BASHEOF
        log_success "Bash aliases added to ~/.bashrc"
    else
        log_info "Bash aliases already present"
    fi
}