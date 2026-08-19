#!/bin/bash
# Module: 04-setup-venv
# Create Python virtual environment and install packages

run_04_setup_venv() {
    setup_venv
}

setup_venv() {
    log_info "Setting up Python virtual environment..."

    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true

    # Determine which user to create venv as
    if sudo -u "$SERVICE_USER" test -w "$REPO_DIR" 2>/dev/null; then
        VENV_AS_USER="$SERVICE_USER"
    else
        # Fallback: find a suitable user
        VENV_AS_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
        if [ "$VENV_AS_USER" = "root" ] || [ -z "$VENV_AS_USER" ]; then
            VENV_AS_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)
        fi
        if [ -z "$VENV_AS_USER" ] || [ "$VENV_AS_USER" = "root" ]; then
            VENV_AS_USER="${USER:-$(id -un)}"
        fi
        if [ -z "$VENV_AS_USER" ] || [ "$VENV_AS_USER" = "root" ]; then
            VENV_AS_USER="$SERVICE_USER"
        fi
        sudo chown -R "$VENV_AS_USER:$VENV_AS_USER" "$REPO_DIR" 2>/dev/null || true
    fi

    if [ ! -d "$VENV_DIR" ]; then
        log_info "Creating venv as user: $VENV_AS_USER"
        sudo -u "$VENV_AS_USER" python3 -m venv "$VENV_DIR"
    fi

    # Ensure service user owns venv for systemd
    if [ "$VENV_AS_USER" != "$SERVICE_USER" ]; then
        sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR" 2>/dev/null || true
    fi

    # Install packages
    log_info "Installing Python packages (litellm[proxy], fastapi)..."
    sudo -u "$VENV_AS_USER" "$VENV_DIR/bin/pip" install --upgrade pip --quiet 2>/dev/null || true
    sudo -u "$VENV_AS_USER" "$VENV_DIR/bin/pip" install 'litellm[proxy]' "fastapi<0.140.0" --quiet

    log_success "Virtual environment ready at $VENV_DIR"
}