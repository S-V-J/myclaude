#!/bin/bash
# MyClaude Docker Entrypoint - Simple and Reliable
# Runs nginx + LiteLLM with on-demand idle monitoring

set -euo pipefail

# Configuration
IDLE_TIMEOUT="${MYCLAUDE_IDLE_TIMEOUT:-300}"
LOCK_FILE="/tmp/myclaude.lock"
STATE_DIR="/tmp/myclaude"
ACTIVITY_FILE="${STATE_DIR}/last_activity"
MONITOR_PID_FILE="${STATE_DIR}/monitor.pid"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[ENTRYPOINT]${NC} $*"; }
log_success() { echo -e "${GREEN}[ENTRYPOINT]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[ENTRYPOINT]${NC} $*"; }
log_error() { echo -e "${RED}[ENTRYPOINT]${NC} $*"; }

mkdir -p "$STATE_DIR"

# ============================================================
# Lock Functions
# ============================================================
acquire_lock() {
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_info "Waiting for lock..."
        flock 200
    fi
}

release_lock() {
    flock -u 200 2>/dev/null || true
    exec 200>&-
}

# ============================================================
# Activity Tracking
# ============================================================
update_activity() {
    date +%s > "$ACTIVITY_FILE"
}

get_last_activity() {
    cat "$ACTIVITY_FILE" 2>/dev/null || echo 0
}

is_idle() {
    local last_activity now
    last_activity=$(get_last_activity)
    now=$(date +%s)
    [ $((now - last_activity)) -gt "$IDLE_TIMEOUT" ]
}

# ============================================================
# Health Check
# ============================================================
wait_for_healthy() {
    local max_wait=30 waited=0 interval=1
    log_info "Waiting for services to become healthy..."
    while [ $waited -lt $max_wait ]; do
        if curl -s --max-time 2 -f "http://localhost:4000/health" >/dev/null 2>&1; then
            log_success "Services are healthy"
            return 0
        fi
        sleep $interval
        waited=$((waited + interval))
        echo -n "."
    done
    echo ""
    log_error "Health check timeout after ${max_wait}s"
    return 1
}

# ============================================================
# Start Services
# ============================================================
start_services() {
    log_info "Starting nginx and LiteLLM..."

    # Generate nginx config with upstream
    cat > /etc/nginx/sites-enabled/myclaude <<'NGINXEOF'
# MyClaude nginx reverse proxy — Production Grade (On-Demand Optimized)

upstream litellm_backend {
    server 127.0.0.1:4001 max_fails=3 fail_timeout=30s;
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

    # Request/response size limits
    client_max_body_size 50M;
    client_body_buffer_size 64k;
    client_header_buffer_size 512;
    large_client_header_buffers 4 8k;

    # Timeouts
    client_body_timeout 60s;
    client_header_timeout 60s;
    send_timeout 3600s;

    # Rate limiting
    limit_req zone=myclaude burst=32 nodelay;
    limit_req_status 503;
    limit_req_log_level warn;

    location / {
        proxy_pass http://litellm_backend;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "";

        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;

        proxy_buffering off;
        proxy_request_buffering off;

        proxy_pass_header Server;
        proxy_pass_header Date;
        proxy_hide_header X-Powered-By;
    }

    location /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
        add_header Cache-Control "no-store";
    }

    location = /health/litellm {
        access_log off;
        proxy_pass http://litellm_backend/health;
        proxy_connect_timeout 5s;
        proxy_read_timeout 10s;
    }

    location = /metrics {
        allow 127.0.0.1;
        allow 10.0.0.0/8;
        allow 172.16.0.0/12;
        allow 192.168.0.0/16;
        deny all;
        proxy_pass http://litellm_backend/metrics;
    }

    location ~ ^/(admin|config|models|keys) {
        deny all;
        return 404;
    }
}
NGINXEOF

    # Add rate limit zone to nginx.conf if not present
    if ! grep -q "limit_req_zone.*myclaude" /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=myclaude:10m rate=16r/s;' /etc/nginx/nginx.conf
    fi

    # Apply on-demand optimizations to nginx.conf
    sed -i 's/^worker_processes auto;/worker_processes 1;/' /etc/nginx/nginx.conf 2>/dev/null || true
    sed -i 's/^worker_processes [0-9]*;/worker_processes 1;/' /etc/nginx/nginx.conf 2>/dev/null || true
    if ! grep -q "worker_connections 1024;" /etc/nginx/nginx.conf; then
        sed -i '/worker_processes 1;/a\worker_connections 1024;' /etc/nginx/nginx.conf
    fi
    if ! grep -q "client_body_buffer_size 64k;" /etc/nginx/nginx.conf; then
        sed -i '/http {/a\    client_body_buffer_size 64k;\n    client_header_buffer_size 512;\n    keepalive_timeout 30s;\n    proxy_buffer_size 4k;\n    proxy_buffers 8 4k;\n    proxy_busy_buffers_size 8k;' /etc/nginx/nginx.conf
    fi

    # Test nginx config
    nginx -t

    # Start nginx (master process stays in foreground with daemon off)
    nginx -g "daemon off; master_process on;" &
    NGINX_PID=$!

    # Start LiteLLM
    /opt/venv/bin/litellm --config /app/config.yaml --port 4001 --host 0.0.0.0 &
    LITELLM_PID=$!

    if wait_for_healthy; then
        log_success "Services started (nginx: $NGINX_PID, litellm: $LITELLM_PID)"
        return 0
    else
        log_warn "Services started but health check failed"
        kill $NGINX_PID $LITELLM_PID 2>/dev/null || true
        wait $NGINX_PID $LITELLM_PID 2>/dev/null || true
        return 1
    fi
}

# ============================================================
# Stop Services
# ============================================================
stop_services() {
    log_info "Stopping services due to idle timeout (${IDLE_TIMEOUT}s)..."
    stop_idle_monitor

    if [ -n "${LITELLM_PID:-}" ] && kill -0 "$LITELLM_PID" 2>/dev/null; then
        kill -TERM "$LITELLM_PID" 2>/dev/null
        wait "$LITELLM_PID" 2>/dev/null || true
    fi

    if [ -n "${NGINX_PID:-}" ] && kill -0 "$NGINX_PID" 2>/dev/null; then
        nginx -s quit 2>/dev/null || kill -TERM "$NGINX_PID" 2>/dev/null
        wait "$NGINX_PID" 2>/dev/null || true
    fi

    log_success "Services stopped"
    rm -f "$ACTIVITY_FILE"
}

# ============================================================
# Idle Monitor
# ============================================================
spawn_idle_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        local existing_pid
        existing_pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            return 0
        fi
    fi

    (
        while true; do
            sleep 30
            exec 200>"$LOCK_FILE"
            if flock -n 200; then
                if is_idle; then
                    stop_services
                    exit 0
                fi
                flock -u 200
            fi
            exec 200>&-
        done
    ) &

    local monitor_pid=$!
    echo "$monitor_pid" > "$MONITOR_PID_FILE"
    log_info "Idle monitor started (PID: $monitor_pid, timeout: ${IDLE_TIMEOUT}s)"
}

stop_idle_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        local pid
        pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            wait "$pid" 2>/dev/null || true
            log_info "Idle monitor stopped"
        fi
        rm -f "$MONITOR_PID_FILE"
    fi
}

# ============================================================
# Signal Handlers
# ============================================================
cleanup() {
    log_info "Received shutdown signal, stopping services..."
    stop_services
    exit 0
}

trap cleanup SIGTERM SIGINT

# ============================================================
# Main - On-Demand Loop
# ============================================================
main() {
    log_info "Starting MyClaude On-Demand Proxy (idle timeout: ${IDLE_TIMEOUT}s)"

    # Initial start
    acquire_lock
    update_activity
    if ! start_services; then
        release_lock
        exit 1
    fi
    spawn_idle_monitor
    release_lock

    log_info "MyClaude proxy ready on ports 4000 (nginx) and 4001 (LiteLLM)"

    # Wait for nginx (main process)
    # When nginx exits (due to idle monitor), restart the loop
    wait $NGINX_PID
    local nginx_exit=$?

    if [ $nginx_exit -eq 0 ] || [ $nginx_exit -eq 143 ]; then
        log_info "Services stopped gracefully, restarting for next activation..."
        sleep 1
        exec "$0" "$@"
    else
        log_error "Nginx exited unexpectedly with code $nginx_exit"
        exit $nginx_exit
    fi
}

main "$@"