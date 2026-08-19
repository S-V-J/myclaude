#!/bin/bash
# Module: 10-setup-claude-code
# Install Claude Code CLI

run_10_setup_claude_code() {
    setup_claude_code
}

setup_claude_code() {
    if [ "$INSTALL_CLAUDE" != "true" ]; then
        log_info "Skipping Claude Code installation (--no-claude)"
        return 0
    fi

    if command -v claude &>/dev/null; then
        log_info "Claude Code already installed: $(claude --version 2>/dev/null || echo 'unknown version')"
        return 0
    fi

    log_info "Installing Claude Code via npm..."

    if command -v npm &>/dev/null; then
        npm install -g @anthropic-ai/claude-code
        log_success "Claude Code installed: $(claude --version)"
    else
        log_error "npm not found. Please install Node.js first."
        log_error "Then run: npm install -g @anthropic-ai/claude-code"
        exit 1
    fi
}