#!/bin/bash
# Module: 03-setup-user
# Create system user and set permissions

run_03_setup_user() {
    setup_system_user
}

setup_system_user() {
    log_info "Setting up system user: $SERVICE_USER"

    if id "$SERVICE_USER" &>/dev/null; then
        if [[ "${AUTO_MODE:-false}" != "true" ]] && [ -t 0 ]; then
            if ! whiptail --title "MyClaude Installer" --yesno "User '$SERVICE_USER' already exists. Re-create it?" 10 70; then
                log_info "Keeping existing user: $SERVICE_USER"
                return 0
            fi
        else
            # In auto mode, just ensure user exists
            log_info "User $SERVICE_USER exists, keeping it."
            return 0
        fi
        sudo userdel -r "$SERVICE_USER" 2>/dev/null || true
    fi

    sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true

    log_success "System user created: $SERVICE_USER"
}