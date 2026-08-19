#!/bin/bash
# Module: 08-setup-logrotate
# Configure log rotation

run_08_setup_logrotate() {
    setup_logrotate
}

setup_logrotate() {
    log_info "Setting up log rotation..."

    if [ -f "$REPO_DIR/logrotate-myclaude" ]; then
        sudo cp "$REPO_DIR/logrotate-myclaude" /etc/logrotate.d/myclaude
        # Update paths in logrotate config to match actual repo directory
        sudo sed -i "s|/home/ML/myclaude|$REPO_DIR|g" /etc/logrotate.d/myclaude
        # Ensure log file exists with correct permissions
        sudo touch "$REPO_DIR/litellm.log"
        sudo chown "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR/litellm.log"
        log_success "Log rotation configured"
    else
        log_warn "logrotate-myclaude not found, skipping"
    fi
}