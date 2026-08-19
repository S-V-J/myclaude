#!/bin/bash
# Fix all issues - run with: sudo bash /home/ML/myclaude/scripts/fix-all.sh

set -euo pipefail

echo "=========================================="
echo "Fixing MyClaude Issues"
echo "=========================================="

# 1. Fix nginx.conf - set worker_processes 1 and add buffer optimizations
echo "1. Fixing nginx.conf..."
sed -i 's/worker_processes auto;/worker_processes 1;/' /etc/nginx/nginx.conf

# Add buffer optimizations to http block if not present
if ! grep -q "client_body_buffer_size 64k;" /etc/nginx/nginx.conf; then
    sed -i '/http {/a\    client_body_buffer_size 64k;\n    client_header_buffer_size 512;\n    keepalive_timeout 30s;\n    worker_connections 1024;' /etc/nginx/nginx.conf
fi

# 2. Fix nginx site config - ensure correct buffer sizes
echo "2. Fixing nginx site config..."
cat > /etc/nginx/sites-enabled/myclaude << 'NGINXEOF'
# MyClaude nginx reverse proxy — Production Grade (On-Demand Optimized)
# Install: sudo cp nginx-myclaude.conf /etc/nginx/sites-available/myclaude
#          sudo ln -sf /etc/nginx/sites-available/myclaude /etc/nginx/sites-enabled/
#          sudo nginx -t && sudo systemctl reload nginx
#
# REQUIRED: Add to /etc/nginx/nginx.conf http block:
# limit_req_zone $binary_remote_addr zone=myclaude:10m rate=50r/s;

# ============================================================
# NGINX OPTIMIZATIONS FOR ON-DEMAND USE
# worker_processes 1;                    # Single worker for low-traffic
# worker_connections 1024;               # Reduced connections
# keepalive_timeout 30s;                 # Shorter keepalive
# client_body_buffer_size 64k;           # Smaller buffers
# client_header_buffer_size 512;         # Smaller header buffer
# ============================================================

# Rate limit zone (must be in http context, not server)
# limit_req_zone $binary_remote_addr zone=myclaude:10m rate=50r/s;

upstream litellm_backend {
    # Primary LiteLLM instance
    server 127.0.0.1:4001 max_fails=3 fail_timeout=30s;
    # Backup for zero-downtime deployments (enable when running 2+ instances)
    # server 127.0.0.1:4002 max_fails=3 fail_timeout=30s backup;

    keepalive 32;
    keepalive_requests 1000;
    keepalive_timeout 60s;
}

server {
    listen 4000;
    listen [::]:4000;
    server_name localhost _;

    # Security headers
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    # Request/response size limits (on-demand optimized)
    client_max_body_size 50M;
    client_body_buffer_size 64k;
    client_header_buffer_size 512;
    large_client_header_buffers 4 8k;

    # Timeouts
    client_body_timeout 60s;
    client_header_timeout 60s;
    send_timeout 3600s;

    # Proxy settings
    location / {
        # Rate limiting (applied ONLY to main traffic, not health/metrics)
        limit_req zone=myclaude burst=100 nodelay;
        limit_req_status 503;
        limit_req_log_level warn;

        proxy_pass http://litellm_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        # WebSocket support & Keepalive
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "";

        # Timeouts
        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;

        # Buffering (caching is disabled by default)
        proxy_buffering off;
        proxy_request_buffering off;

        # Pass through important headers
        proxy_pass_header Server;
        proxy_pass_header Date;
        proxy_hide_header X-Powered-By;
    }

    # Health check endpoint (no rate limit, no auth)
    location = /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
        add_header Cache-Control "no-store";
    }

    # LiteLLM health (proxied)
    location = /health/litellm {
        access_log off;
        proxy_pass http://litellm_backend/health;
        proxy_connect_timeout 5s;
        proxy_read_timeout 10s;
    }

    # Metrics endpoint (restrict in production)
    location = /metrics {
        allow 127.0.0.1;
        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 192.168.0.0/16;
        deny all;
        proxy_pass http://litellm_backend/metrics;
    }

    # Deny all other admin paths
    location ~ ^/(admin|config|models|keys) {
        deny all;
        return 404;
    }
}
NGINXEOF

# 3. Test and reload nginx
echo "3. Testing nginx config..."
nginx -t
systemctl reload nginx

# 4. Kill duplicate litellm process on port 4000
echo "4. Killing duplicate litellm on port 4000..."
pkill -f "litellm.*port 4000" 2>/dev/null || true

# 5. Update systemd service with correct template
echo "5. Updating systemd service..."
cp /home/ML/myclaude/litellm.service.template /etc/systemd/system/myclaude.service
sed -i 's|__REPO_DIR__|/home/ML/myclaude|g' /etc/systemd/system/myclaude.service
sed -i 's|__VENV_DIR__|/home/ML/myclaude/venv|g' /etc/systemd/system/myclaude.service
sed -i 's|__SERVICE_USER__|ML|g' /etc/systemd/system/myclaude.service
sed -i 's|__PORT__|4001|g' /etc/systemd/system/myclaude.service
systemctl daemon-reload

# 6. Restart myclaude service
echo "6. Restarting myclaude service..."
systemctl restart myclaude
sleep 3

# 7. Verify
echo "7. Verifying..."
sleep 2
curl -s http://localhost:4000/health
echo ""
curl -s http://localhost:4000/health/litellm
echo ""

# 8. Show memory
echo "8. Memory usage:"
ps aux | awk '/[l]itellm|[n]ginx: worker/ {sum+=$6; print $0} END {print "Total RSS: " sum/1024 " MB"}'

echo ""
echo "=========================================="
echo "Fix Complete!"
echo "=========================================="