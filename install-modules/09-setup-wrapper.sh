#!/bin/bash
# Module: 09-setup-wrapper
# Install myclaude wrapper command

run_09_setup_wrapper() {
    setup_wrapper
}

setup_wrapper() {
    log_info "Installing myclaude wrapper..."

    # Use the myclaude.sh from repo (already enhanced with on-demand logic)
    sudo cp "$REPO_DIR/myclaude.sh" /usr/local/bin/myclaude
    sudo chmod +x /usr/local/bin/myclaude

    log_success "Wrapper installed at /usr/local/bin/myclaude"
}