#!/bin/bash
# Module: 05-write-env
# Write .env file with API keys and configuration

run_05_write_env() {
    write_env_file
}

write_env_file() {
    log_info "Writing .env configuration..."

    # Generate local master key
    LOCAL_KEY="sk-local-$(openssl rand -hex 16 2>/dev/null || echo "proxykey$(date +%s)")"

    cat > "$REPO_DIR/.env" <<ENVEOF
# MyClaude Environment Configuration
# Generated: $(date)
NVIDIA_API_KEY_PROJECT_1="$NVIDIA_API_KEY_PROJECT_1"
ENVEOF

    if [ -n "${NVIDIA_API_KEY_PROJECT_2:-}" ]; then
        echo "NVIDIA_API_KEY_PROJECT_2=\"$NVIDIA_API_KEY_PROJECT_2\"" >> "$REPO_DIR/.env"
    fi
    if [ -n "${NVIDIA_API_KEY_PROJECT_3:-}" ]; then
        echo "NVIDIA_API_KEY_PROJECT_3=\"$NVIDIA_API_KEY_PROJECT_3\"" >> "$REPO_DIR/.env"
    fi
    if [ -n "${NVIDIA_API_KEY_PROJECT_4:-}" ]; then
        echo "NVIDIA_API_KEY_PROJECT_4=\"$NVIDIA_API_KEY_PROJECT_4\"" >> "$REPO_DIR/.env"
    fi

    cat >> "$REPO_DIR/.env" <<ENVEOF
LITELLM_MASTER_KEY="$LOCAL_KEY"
LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="true"

# On-demand configuration
MYCLAUDE_IDLE_TIMEOUT=300
ENVEOF

    # Secure the .env file
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR/.env" 2>/dev/null || true
    chmod 600 "$REPO_DIR/.env"

    log_success ".env written with $(grep -c 'NVIDIA_API_KEY' "$REPO_DIR/.env") API key(s)"
}