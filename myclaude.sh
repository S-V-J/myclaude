#!/bin/bash
# myclaude — Smart Launcher for Claude Code via MyClaude Proxy
# Auto-detects issues, self-heals, monitors health, ensures smooth operation
# Installed to /usr/local/bin/myclaude by install.sh

set -euo pipefail

# ============================================================
# Configuration & Constants
# ============================================================
SERVICE_NAME="myclaude"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"
REPO_DIR="${MYCLAUDE_INSTALL_DIR:-/home/ML/myclaude}"

IDLE_TIMEOUT="${MYCLAUDE_IDLE_TIMEOUT:-0}"
STARTUP_LOCK_FILE="/tmp/myclaude-startup.lock"
MONITOR_LOCK_FILE="/tmp/myclaude-monitor.lock"
STATE_DIR="/tmp/myclaude"
ACTIVITY_FILE="${STATE_DIR}/last_activity"
MONITOR_PID_FILE="${STATE_DIR}/monitor.pid"
STARTUP_RETRIES=10
STARTUP_RETRY_DELAY=10
HEALTH_CHECK_INTERVAL=30
MAX_HEALTH_FAILURES=10

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }
log_debug()   { echo -e "${CYAN}[DEBUG]${NC} $*"; }

mkdir -p "$STATE_DIR"

# ============================================================
# Lock Functions (separate locks for startup and monitor)
# ============================================================
STARTUP_LOCK_FILE="/tmp/myclaude-startup.lock"
MONITOR_LOCK_FILE="/tmp/myclaude-monitor.lock"

acquire_startup_lock() {
    exec 200>"$STARTUP_LOCK_FILE"
    if ! flock -n 200; then
        log_info "Another myclaude instance is starting backend, waiting up to 10s..."
        local waited=0
        while [ $waited -lt 10 ]; do
            if flock -n 200; then return 0; fi
            sleep 1
            waited=$((waited + 1))
        done
        log_warn "Could not acquire startup lock, proceeding anyway (backend may already be running)"
        return 1
    fi
}

release_startup_lock() {
    flock -u 200 2>/dev/null || true
    exec 200>&-
}

acquire_monitor_lock() {
    exec 201>"$MONITOR_LOCK_FILE"
    if ! flock -n 201; then
        return 1  # Don't wait - just skip this check cycle
    fi
}

release_monitor_lock() {
    flock -u 201 2>/dev/null || true
    exec 201>&-
}

# ============================================================
# Smart Pre-Flight Checks & Auto-Fix
# ============================================================
check_and_fix() {
    local issues=0
    local fixes=0

    log_info "🔍 Running pre-flight checks..."

    # 1. Check .env exists and has required keys
    if [ ! -f "$REPO_DIR/.env" ]; then
        log_error "Missing .env file at $REPO_DIR/.env"
        ((issues++))
    else
        if ! grep -q "NVIDIA_API_KEY_PROJECT_1" "$REPO_DIR/.env"; then
            log_error "NVIDIA_API_KEY_PROJECT_1 not set in .env"
            ((issues++))
        fi
        if ! grep -q "LITELLM_MASTER_KEY" "$REPO_DIR/.env"; then
            log_warn "LITELLM_MASTER_KEY missing, will use default"
        fi
    fi

    # 2. Check config.yaml
    if [ ! -f "$REPO_DIR/config.yaml" ]; then
        log_error "Missing config.yaml at $REPO_DIR/config.yaml"
        ((issues++))
    fi

    # 3. Check venv and litellm
    if [ ! -f "$REPO_DIR/venv/bin/litellm" ]; then
        log_warn "litellm not found in venv, attempting reinstall..."
        if command -v python3 >/dev/null; then
            python3 -m venv "$REPO_DIR/venv" 2>/dev/null || true
            "$REPO_DIR/venv/bin/pip" install --quiet 'litellm[proxy]' "fastapi<0.140.0" 2>/dev/null && ((fixes++))
        fi
    fi

    # 4. Check nginx config
    if [ ! -f "$NGINX_CONF" ]; then
        log_warn "nginx config missing, restoring from template..."
        if [ -f "$REPO_DIR/nginx-myclaude.conf" ]; then
            sudo cp "$REPO_DIR/nginx-myclaude.conf" "$NGINX_CONF"
            sudo nginx -t 2>/dev/null && sudo systemctl reload nginx && ((fixes++))
        fi
    else
        # Validate nginx syntax
        if ! sudo nginx -t 2>/dev/null; then
            log_warn "nginx config invalid, restoring..."
            sudo cp "$REPO_DIR/nginx-myclaude.conf" "$NGINX_CONF"
            sudo nginx -t 2>/dev/null && sudo systemctl reload nginx && ((fixes++))
        fi
    fi

    # 5. Check rate limit zone in nginx.conf
    if ! grep -q "limit_req_zone.*myclaude" /etc/nginx/nginx.conf 2>/dev/null; then
        log_warn "Adding rate limit zone to nginx.conf..."
        sudo sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=myclaude:10m rate=16r/s;' /etc/nginx/nginx.conf
        sudo nginx -t 2>/dev/null && sudo systemctl reload nginx && ((fixes++))
    fi

    # 6. Check systemd service
    if [ ! -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
        log_warn "systemd service missing, recreating..."
        if [ -f "$REPO_DIR/litellm.service.template" ]; then
            local svc
            svc=$(mktemp)
            sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
                -e "s|__VENV_DIR__|$REPO_DIR/venv|g" \
                -e "s|__SERVICE_USER__|$USER|g" \
                -e "s|__PORT__|4001|g" \
                "$REPO_DIR/litellm.service.template" > "$svc"
            sudo cp "$svc" "/etc/systemd/system/${SERVICE_NAME}.service"
            rm -f "$svc"
            sudo systemctl daemon-reload
            ((fixes++))
        fi
    fi

    # 7. Check and fix service restart policy (must be on-failure for idle shutdown)
    if grep -q "^Restart=always" /etc/systemd/system/${SERVICE_NAME}.service 2>/dev/null; then
        log_warn "Fixing systemd Restart policy (always -> on-failure)..."
        sudo sed -i 's/^Restart=always/Restart=on-failure/' /etc/systemd/system/${SERVICE_NAME}.service
        sudo systemctl daemon-reload
        ((fixes++))
    fi

    # 8. Check ports
    if ! ss -tlnp 2>/dev/null | grep -q ':4000 '; then
        log_info "Port 4000 (nginx) not listening, will start services"
    fi
    if ! ss -tlnp 2>/dev/null | grep -q ':4001 '; then
        log_info "Port 4001 (LiteLLM) not listening, will start services"
    fi

    # 9. Clean stale lock files
    find /tmp -maxdepth 1 -name 'myclaude*.lock' -mmin +60 -delete 2>/dev/null || true
    find /tmp -maxdepth 1 -name 'myclaude' -type d -mmin +60 -exec rm -rf {} + 2>/dev/null || true

    if [ $issues -gt 0 ]; then
        log_error "Pre-flight: $issues critical issue(s) found"
        return 1
    fi
    if [ $fixes -gt 0 ]; then
        log_success "Auto-fixed $fixes issue(s)"
    fi
    log_success "Pre-flight checks passed"
    return 0
}

# ============================================================
# Memory & Health Reporting
# ============================================================
report_memory() {
    local label="${1:-Current}"
    local mem_mb
    mem_mb=$(ps aux | awk '/[l]itellm|[n]ginx: worker/ {sum+=$6} END {print sum/1024}' 2>/dev/null || echo "0")
    log_debug "${label} RAM: ${mem_mb} MB"
}

# ============================================================
# Activity Tracking
# ============================================================
update_activity() { date +%s > "$ACTIVITY_FILE"; }
get_last_activity() { cat "$ACTIVITY_FILE" 2>/dev/null || echo 0; }
is_idle() {
    local last_activity now
    last_activity=$(get_last_activity)
    now=$(date +%s)
    # IDLE_TIMEOUT=0 means no idle shutdown
    [ "$IDLE_TIMEOUT" -gt 0 ] && [ $((now - last_activity)) -gt "$IDLE_TIMEOUT" ]
}

# ============================================================
# Backend Health Check (comprehensive)
# ============================================================
get_master_key() {
    if [ -f "$REPO_DIR/.env" ]; then
        grep "LITELLM_MASTER_KEY" "$REPO_DIR/.env" | cut -d'"' -f2
    else
        echo "sk-local-proxy-key"
    fi
}

check_health() {
    local failures=0
    local master_key
    master_key=$(get_master_key)

    # Check nginx (no auth needed) - this confirms nginx is running and reachable
    log_debug "Checking nginx health: http://localhost:4000/health"
    if ! curl -s --max-time 30 -f "http://localhost:4000/health" >/dev/null 2>&1; then
        log_warn "nginx health check FAILED"
        ((failures++))
    else
        log_debug "nginx health check OK"
    fi

    # Check LiteLLM direct on port 4001 with auth (this works)
    log_debug "Checking LiteLLM direct: http://localhost:4001/health"
    if ! curl -s --max-time 60 -f -H "Authorization: Bearer $master_key" "http://localhost:4001/health" >/dev/null 2>&1; then
        log_warn "LiteLLM direct health check FAILED"
        ((failures++))
    else
        log_debug "LiteLLM direct health check OK"
    fi

    return $failures
}

wait_for_healthy() {
    local max_wait=0  # 0 = no timeout, wait indefinitely
    local waited=0
    local interval=5
    local consecutive_failures=0

    log_info "Waiting for backend to become healthy (no timeout)..."
    while [ $max_wait -eq 0 ] || [ $waited -lt $max_wait ]; do
        if check_health; then
            if [ $consecutive_failures -gt 0 ]; then
                echo ""  # New line after dots
            fi
            log_success "Backend healthy (nginx + LiteLLM) - took ${waited}s"
            report_memory "Post-startup"
            return 0
        fi
        sleep $interval
        waited=$((waited + interval))
        consecutive_failures=$((consecutive_failures + 1))
        # Show progress every 15 seconds
        if [ $((waited % 15)) -eq 0 ]; then
            echo -n "."
        elif [ $((waited % 5)) -eq 0 ]; then
            echo -n "."
        fi
        # Show detailed status every 60 seconds
        if [ $((waited % 60)) -eq 0 ] && [ $waited -gt 0 ]; then
            echo ""
            log_info "Still waiting... (${waited}s elapsed) - checking: nginx=/health, litellm=/health"
        fi
    done
    echo ""
    log_error "Backend health check timeout after ${max_wait}s"
    log_error "Last diagnostics:"
    curl -v http://localhost:4000/health 2>&1 | tail -5
    curl -v -H "Authorization: Bearer $(get_master_key)" http://localhost:4001/health 2>&1 | tail -5
    return 1
}

# ============================================================
# Start Backend with Retry & Diagnostics
# ============================================================
start_backend() {
    local attempt=1

    while [ $attempt -le $STARTUP_RETRIES ]; do
        if [ $attempt -gt 1 ]; then
            local delay=$((STARTUP_RETRY_DELAY * (2 ** (attempt - 2))))
            log_warn "Retry $attempt/$STARTUP_RETRIES after ${delay}s..."
            sleep $delay
        fi

        log_info "Starting MyClaude backend (attempt $attempt/$STARTUP_RETRIES)..."
        if sudo systemctl start "$SERVICE_NAME"; then
            if wait_for_healthy; then
                log_success "MyClaude backend started successfully"
                return 0
            else
                log_warn "Backend started but health check failed"
                # Diagnose
                log_info "Diagnosing failure..."
                journalctl -u "$SERVICE_NAME" -n 20 --no-pager 2>/dev/null | tail -20
                sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            fi
        else
            log_warn "systemctl start failed"
            journalctl -u "$SERVICE_NAME" -n 10 --no-pager 2>/dev/null | tail -10
        fi

        attempt=$((attempt + 1))
    done

    log_error "Failed to start backend after $STARTUP_RETRIES attempts"
    log_error "Check: journalctl -u $SERVICE_NAME -n 30"
    return 1
}

# ============================================================
# Stop Backend Gracefully
# ============================================================
stop_backend() {
    log_info "Stopping MyClaude backend due to idle timeout (${IDLE_TIMEOUT}s)..."
    report_memory "Pre-shutdown"

    # Stop the monitor first
    stop_idle_monitor

    # Stop systemd service (stops both LiteLLM and nginx via dependencies)
    if sudo systemctl stop "$SERVICE_NAME"; then
        log_success "MyClaude backend stopped"
    else
        log_warn "systemctl stop returned non-zero (service may already be stopped)"
    fi

    # Clear activity file
    rm -f "$ACTIVITY_FILE"
    report_memory "Post-shutdown"
}

# ============================================================
# Idle Monitor (background process)
# ============================================================
spawn_idle_monitor() {
    # If IDLE_TIMEOUT is 0, don't start idle monitor (always-on mode)
    if [ "$IDLE_TIMEOUT" -eq 0 ]; then
        log_info "Always-on mode enabled (IDLE_TIMEOUT=0), idle monitor disabled"
        return 0
    fi

    # Check if monitor is already running
    if [ -f "$MONITOR_PID_FILE" ]; then
        local existing_pid
        existing_pid=$(cat "$MONITOR_PID_FILE" 2>/dev/null)
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            return 0  # Monitor already running
        fi
    fi

    (
        # Child process - idle monitor
        while true; do
            sleep 30

            # Acquire monitor lock to safely check/stop (non-blocking)
            if acquire_monitor_lock; then
                if is_idle; then
                    stop_backend
                fi
                release_monitor_lock
            fi
            # If couldn't acquire lock, skip this cycle - another monitor check is running
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
# Session Health Monitor (runs in background during Claude session)
# ============================================================
SESSION_MONITOR_PID=""

start_session_monitor() {
    (
        local failures=0
        while true; do
            sleep $HEALTH_CHECK_INTERVAL
            if ! check_health; then
                failures=$((failures + 1))
                log_warn "Health check failed ($failures/$MAX_HEALTH_FAILURES)"
                if [ $failures -ge $MAX_HEALTH_FAILURES ]; then
                    log_error "Too many health failures, attempting recovery..."
                    sudo systemctl restart "$SERVICE_NAME" 2>/dev/null
                    sleep 3
                    if check_health; then
                        log_success "Auto-recovery successful"
                        failures=0
                    else
                        log_error "Auto-recovery failed"
                    fi
                fi
            else
                failures=0
            fi
        done
    ) &

    SESSION_MONITOR_PID=$!
    log_debug "Session monitor started (PID: $SESSION_MONITOR_PID)"
}

stop_session_monitor() {
    if [ -n "$SESSION_MONITOR_PID" ] && kill -0 "$SESSION_MONITOR_PID" 2>/dev/null; then
        kill "$SESSION_MONITOR_PID" 2>/dev/null
        wait "$SESSION_MONITOR_PID" 2>/dev/null || true
        log_debug "Session monitor stopped"
    fi
}

# ============================================================
# Cleanup on Exit
# ============================================================
cleanup() {
    # Update activity one last time (so monitor doesn't stop immediately if user restarts quickly)
    update_activity
    # Don't stop idle monitor here - let it handle idle timeout naturally
    # But stop session monitor
    stop_session_monitor
}
trap cleanup EXIT

# ============================================================
# Main Logic
# ============================================================
main() {
    # Acquire lock for startup critical section
    acquire_startup_lock

    # Update activity timestamp
    update_activity

    # Check if backend is running
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        # Backend not running - start it
        if ! start_backend; then
            release_startup_lock
            exit 1
        fi
    else
        log_info "MyClaude backend already running"
        # Verify it's actually healthy
        if ! check_health; then
            log_warn "Backend running but unhealthy, restarting..."
            sudo systemctl restart "$SERVICE_NAME"
            sleep 3
            if ! wait_for_healthy; then
                release_startup_lock
                exit 1
            fi
        fi
    fi

    # Spawn/restart idle monitor
    spawn_idle_monitor

    # Release lock before launching Claude Code (allows concurrent invocations)
    release_startup_lock

    # Start session health monitor
    start_session_monitor

    # Read the local proxy key from .env
    local repo_dir
    repo_dir=$(dirname "$(readlink -f "/usr/local/bin/myclaude")")
    local local_key="sk-local-proxy-key"
    if [ -f "$repo_dir/.env" ]; then
        local_key=$(grep "LITELLM_MASTER_KEY" "$repo_dir/.env" | cut -d'"' -f2)
    fi

    # Detect if TLS is enabled (check nginx config for port 4443)
    if grep -qE "^[^#]*listen 4443" "$NGINX_CONF" 2>/dev/null; then
        export ANTHROPIC_BASE_URL="https://localhost:4443"
        export NODE_TLS_REJECT_UNAUTHORIZED=0
        export ANTHROPIC_API_KEY="$local_key"
        log_info "Launching Claude Code via MyClaude proxy (HTTPS)..."
    else
        export ANTHROPIC_BASE_URL="http://localhost:4000"
        export ANTHROPIC_API_KEY="$local_key"
        log_info "Launching Claude Code via MyClaude proxy (HTTP)..."
    fi

    # Execute Claude Code - this blocks until user exits
    cleanup
    exec claude "$@"
}

main "$@"