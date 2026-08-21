#!/bin/bash
# myclaude wrapper — launches Claude Code through the LiteLLM proxy
# Installed to /usr/local/bin/myclaude by install.sh
# Supports on-demand activation with idle shutdown

set -euo pipefail

SERVICE_NAME="myclaude"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"

# On-demand configuration (can be overridden via environment)
IDLE_TIMEOUT="${MYCLAUDE_IDLE_TIMEOUT:-300}"  # 5 minutes default
LOCK_FILE="/tmp/myclaude.lock"
STARTUP_LOCK_FILE="/tmp/myclaude-startup.lock"
MONITOR_LOCK_FILE="/tmp/myclaude-monitor.lock"
STATE_DIR="/tmp/myclaude"
ACTIVITY_FILE="${STATE_DIR}/last_activity"
MONITOR_PID_FILE="${STATE_DIR}/monitor.pid"
STARTUP_RETRIES=3
STARTUP_RETRY_DELAY=2

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# ============================================================
# Lock Functions (prevent race conditions)
# ============================================================
# Use separate lock files: one for startup, one for idle monitor
STARTUP_LOCK_FILE="/tmp/myclaude-startup.lock"
MONITOR_LOCK_FILE="/tmp/myclaude-monitor.lock"

acquire_startup_lock() {
    exec 200>"$STARTUP_LOCK_FILE"
    # Non-blocking with timeout - fail fast if can't get lock
    if ! flock -n 200; then
        log_info "Another myclaude instance is starting backend, waiting up to 10s..."
        # Wait with timeout - don't block forever
        local waited=0
        while [ $waited -lt 10 ]; do
            if flock -n 200; then
                return 0
            fi
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
# Memory Reporting
# ============================================================
report_memory_usage() {
    local label="${1:-Current}"
    local mem_mb
    mem_mb=$(ps aux | awk '/[l]itellm|[n]ginx: worker/ {sum+=$6} END {print sum/1024}' 2>/dev/null || echo "0")
    log_info "${label} RAM usage: ${mem_mb} MB"
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
    local last_activity
    last_activity=$(get_last_activity)
    local now
    now=$(date +%s)
    [ $((now - last_activity)) -gt "$IDLE_TIMEOUT" ]
}

# ============================================================
# Backend Health Check
# ============================================================
wait_for_healthy() {
    local max_wait=30
    local waited=0
    local interval=1

    log_info "Waiting for backend to become healthy..."
    while [ $waited -lt $max_wait ]; do
        # Check LiteLLM health through nginx (port 4000/health/litellm) - tests full proxy stack
        if curl -s --max-time 2 -f "http://localhost:4000/health/litellm" >/dev/null 2>&1; then
            log_success "Backend is healthy"
            return 0
        fi
        sleep $interval
        waited=$((waited + interval))
        echo -n "."
    done
    echo ""
    log_error "Backend health check timeout after ${max_wait}s"
    return 1
}

# ============================================================
# Start Backend with Retry Logic
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
                report_memory_usage "Post-startup"
                return 0
            else
                log_warn "Backend started but health check failed"
                sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
            fi
        else
            log_warn "systemctl start failed"
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
    report_memory_usage "Pre-shutdown"

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
    report_memory_usage "Post-shutdown"
}

# ============================================================
# Idle Monitor (background process)
# ============================================================
spawn_idle_monitor() {
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
# Cleanup on Exit
# ============================================================
cleanup() {
    # Update activity one last time (so monitor doesn't stop immediately if user restarts quickly)
    update_activity
    # Don't stop monitor here - let it handle idle timeout naturally
    # But if we're the last claude process, monitor will stop backend after timeout
}
trap cleanup EXIT

# ============================================================
# Main Logic
# ============================================================
main() {
    # Acquire startup lock for startup critical section (with timeout)
    acquire_startup_lock || true

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
    fi

    # Spawn/restart idle monitor
    spawn_idle_monitor

    # Release startup lock before launching Claude Code (allows concurrent invocations)
    release_startup_lock

    # Read the local proxy key from .env
    local repo_dir
    repo_dir=$(dirname "$(readlink -f "/usr/local/bin/myclaude")")
    local local_key="sk-local-proxy-key"
    if [ -f "$repo_dir/.env" ]; then
        local_key=$(grep "LITELLM_MASTER_KEY" "$repo_dir/.env" | cut -d'"' -f2)
    fi

    # Detect if TLS is enabled (check nginx config for port 4443)
    if grep -q "listen 4443" "$NGINX_CONF" 2>/dev/null; then
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
    # Note: cleanup trap runs on shell exit, but exec replaces the process
    # So we run cleanup manually before exec
    cleanup
    exec claude "$@"
}

main "$@"