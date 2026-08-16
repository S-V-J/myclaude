#!/bin/bash
# myclaude wrapper — launches Claude Code through the LiteLLM proxy
# Installed to /usr/local/bin/myclaude by install.sh

SERVICE_NAME="myclaude"

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

export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_API_KEY="sk-local-proxy-key"

echo "Launching Claude Code via MyClaude proxy..."
exec claude "$@"