#!/bin/bash
# myclaude wrapper — launches Claude Code through the LiteLLM proxy
# Installed to /usr/local/bin/myclaude by install.sh

SERVICE_NAME="myclaude"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"

# Check if service is active, start if not
if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Starting MyClaude proxy..."
    sudo systemctl start "$SERVICE_NAME"
    sleep 3
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "Failed to start. Check: journalctl -u $SERVICE_NAME -n 20"
        exit 1
    fi
fi

# Detect if TLS is enabled (check nginx config for port 4443)
if grep -q "listen 4443" "$NGINX_CONF" 2>/dev/null; then
    export ANTHROPIC_BASE_URL="https://localhost:4443"
    # Allow self-signed cert for local development
    export ANTHROPIC_API_KEY="sk-local-proxy-key"
    echo "Launching Claude Code via MyClaude proxy (HTTPS)..."
else
    export ANTHROPIC_BASE_URL="http://localhost:4000"
    export ANTHROPIC_API_KEY="sk-local-proxy-key"
    echo "Launching Claude Code via MyClaude proxy (HTTP)..."
fi

exec claude "$@"