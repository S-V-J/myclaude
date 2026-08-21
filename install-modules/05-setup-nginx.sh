#!/bin/bash
# Module 05: Setup nginx reverse proxy with TLS
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Setting up nginx..."

# Create self-signed certificate
sudo mkdir -p /etc/nginx/ssl
if [[ ! -f /etc/nginx/ssl/myclaude.crt ]]; then
    sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /etc/nginx/ssl/myclaude.key \
        -out /etc/nginx/ssl/myclaude.crt \
        -subj "/CN=localhost" 2>/dev/null
    log_info "Self-signed certificate created"
fi

# Copy nginx config from template
sudo cp "$REPO_DIR/nginx-myclaude.conf" /etc/nginx/sites-available/myclaude

if [ "$ENABLE_LAN" = true ]; then
    sudo sed -i 's|^listen 4000;|listen 0.0.0.0:4000;|g' /etc/nginx/sites-available/myclaude
    sudo sed -i 's|^listen 4000 default_server;|listen 0.0.0.0:4000 default_server;|g' /etc/nginx/sites-available/myclaude
fi

# Enable site
sudo ln -sf /etc/nginx/sites-available/myclaude /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Add rate limiting zone to nginx.conf http block if not present
if ! grep -q "limit_req_zone.*myclaude" /etc/nginx/nginx.conf 2>/dev/null; then
    sudo sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=myclaude:10m rate=16r/s;' /etc/nginx/nginx.conf
fi

# On-demand optimizations: reduce worker processes and buffer sizes
# These settings are applied when on-demand mode is detected (MYCLAUDE_IDLE_TIMEOUT > 0)
if ! grep -q "worker_processes 1;" /etc/nginx/nginx.conf 2>/dev/null; then
    # Check if we should optimize for on-demand
    if [ -f "$REPO_DIR/.env" ] && grep -q "MYCLAUDE_IDLE_TIMEOUT" "$REPO_DIR/.env"; then
        local idle_timeout
        idle_timeout=$(grep "MYCLAUDE_IDLE_TIMEOUT" "$REPO_DIR/.env" | cut -d= -f2)
        if [ "$idle_timeout" -gt 0 ] 2>/dev/null; then
            log_info "Applying on-demand nginx optimizations (worker_processes=1)..."
            sudo sed -i 's/^worker_processes auto;/worker_processes 1;/' /etc/nginx/nginx.conf
            # Also add smaller buffer settings if not present
            if ! grep -q "client_body_buffer_size 64k;" /etc/nginx/nginx.conf 2>/dev/null; then
                sudo sed -i '/http {/a\    client_body_buffer_size 64k;\n    client_header_buffer_size 512;\n    keepalive_timeout 30s;' /etc/nginx/nginx.conf
            fi
        fi
    fi
fi

# Test config
sudo nginx -t
log_info "nginx configuration complete"