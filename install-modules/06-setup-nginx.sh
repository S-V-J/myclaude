#!/bin/bash
# Module: 06-setup-nginx
# Configure nginx with on-demand optimizations

run_06_setup_nginx() {
    setup_nginx
}

setup_nginx() {
    log_info "Configuring nginx (on-demand optimized)..."

    # Copy nginx site config
    sudo rm -f "$NGINX_CONF"
    sudo cp "$REPO_DIR/nginx-myclaude.conf" "$NGINX_CONF"

    # LAN access
    if [ "$ENABLE_LAN" = true ]; then
        sudo sed -i 's|^listen 4000;|listen 0.0.0.0:4000;|g' "$NGINX_CONF"
        sudo sed -i 's|^listen 4000 default_server;|listen 0.0.0.0:4000 default_server;|g' "$NGINX_CONF"
    fi

    # Rate limiting zone - add to nginx.conf http block
    if ! grep -q "limit_req_zone.*myclaude" /etc/nginx/nginx.conf 2>/dev/null; then
        sudo sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=myclaude:10m rate='"${NGINX_RATE}"'r/s;' /etc/nginx/nginx.conf
    else
        # Update existing rate
        sudo sed -i "s|rate=[0-9]*r/s|rate=${NGINX_RATE}r/s|g" /etc/nginx/nginx.conf
    fi

    # Update burst in site config
    sudo sed -i "s|burst=[0-9]*|burst=${NGINX_BURST}|g" "$NGINX_CONF"

    # ============================================================
    # ON-DEMAND NGINX OPTIMIZATIONS
    # Applied to nginx.conf http block
    # ============================================================
    log_info "Applying on-demand nginx optimizations..."

    # 1. worker_processes 1 (single worker for low-traffic on-demand)
    if grep -q "^worker_processes auto;" /etc/nginx/nginx.conf; then
        sudo sed -i 's/^worker_processes auto;/worker_processes 1;/' /etc/nginx/nginx.conf
        log_info "  Set worker_processes = 1"
    elif grep -q "^worker_processes [0-9]*;" /etc/nginx/nginx.conf; then
        sudo sed -i 's/^worker_processes [0-9]*;/worker_processes 1;/' /etc/nginx/nginx.conf
        log_info "  Set worker_processes = 1"
    fi

    # 2. worker_connections 1024 (reduced for on-demand)
    if ! grep -q "worker_connections 1024;" /etc/nginx/nginx.conf; then
        sudo sed -i '/worker_processes 1;/a\worker_connections 1024;' /etc/nginx/nginx.conf
        log_info "  Set worker_connections = 1024"
    fi

    # 3. Add buffer optimizations to http block
    if ! grep -q "client_body_buffer_size 64k;" /etc/nginx/nginx.conf; then
        sudo sed -i '/http {/a\    client_body_buffer_size 64k;\n    client_header_buffer_size 512;\n    keepalive_timeout 30s;\n    proxy_buffer_size 4k;\n    proxy_buffers 8 4k;\n    proxy_busy_buffers_size 8k;' /etc/nginx/nginx.conf
        log_info "  Added buffer optimizations (64k/512/30s)"
    fi

    # Test and reload
    if sudo nginx -t 2>&1 | grep -q "successful"; then
        sudo systemctl reload nginx
        log_success "Nginx configured and reloaded"
    else
        log_error "Nginx config test failed"
        sudo nginx -t
        exit 1
    fi
}