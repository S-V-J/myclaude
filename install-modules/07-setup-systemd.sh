#!/bin/bash
# Module: 07-setup-systemd
# Configure systemd service

run_07_setup_systemd() {
    setup_systemd
}

setup_systemd() {
    log_info "Configuring systemd service..."

    sudo chown "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR/.env" 2>/dev/null || true
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR" 2>/dev/null || true

    local svc
    svc=$(mktemp)
    sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
        -e "s|__VENV_DIR__|$VENV_DIR|g" \
        -e "s|__SERVICE_USER__|$SERVICE_USER|g" \
        "$REPO_DIR/litellm.service.template" > "$svc"

    sudo cp "$svc" "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "$svc"

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME" 2>/dev/null || true

    # Start service
    sudo systemctl restart "$SERVICE_NAME"

    sleep 3
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        log_error "myclaude.service failed to start"
        log_error "Check: journalctl -u $SERVICE_NAME -n 20"
        exit 1
    fi

    log_success "Systemd service active: $SERVICE_NAME"
}