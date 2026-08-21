#!/bin/bash
# Module 08: Setup myclaude wrapper script with on-demand start/stop
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Setting up myclaude wrapper script..."

cat > "$REPO_DIR/myclaude-wrapper.sh" <<'WRAPEOF'
#!/bin/bash
# MyClaude Wrapper - On-demand backend with idle shutdown
# Starts nginx + litellm when invoked, stops after 5 min idle

set -euo pipefail

# Determine repo directory dynamically
if [[ "${BASH_SOURCE[0]}" == /* ]]; then
    REPO_DIR="$(dirname "${BASH_SOURCE[0]}")"
else
    REPO_DIR="$(pwd)"
fi
VENV_DIR="$REPO_DIR/venv"
LOCK_FILE="/tmp/myclaude.lock"
PID_FILE="/tmp/myclaude.pid"
IDLE_TIMEOUT="${MYCLAUDE_IDLE_TIMEOUT:-300}"  # 5 minutes default
LOG_FILE="$REPO_DIR/logs/wrapper.log"

# Ensure log directory exists
mkdir -p "$REPO_DIR/logs"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Acquire lock to prevent concurrent starts
exec 9>"$LOCK_FILE"
flock -n 9 || { log "Another myclaude instance is starting, waiting..."; flock 9; }

# Check if service is already running
if systemctl is-active --quiet myclaude 2>/dev/null; then
    log "Service already running"
else
    log "Starting myclaude service..."
    sudo systemctl start myclaude
    sudo systemctl start nginx

    # Wait for service to be ready
    for i in {1..30}; do
        if curl -sfk https://localhost:4000/health >/dev/null 2>&1; then
            log "Service ready"
            break
        fi
        sleep 1
    done
fi

# Start idle monitor in background
(
    while true; do
        sleep 30
        if ! systemctl is-active --quiet myclaude 2>/dev/null; then
            exit 0
        fi
        # Check if any requests in last $IDLE_TIMEOUT seconds
        if [[ -f /var/log/nginx/myclaude_access.log ]]; then
            last_req=$(stat -c %Y /var/log/nginx/myclaude_access.log)
            now=$(date +%s)
            if (( now - last_req > IDLE_TIMEOUT )); then
                log "Idle timeout ($IDLE_TIMEOUT s) reached, stopping service..."
                sudo systemctl stop myclaude
                sudo systemctl stop nginx
                exit 0
            fi
        fi
    done
) &

MONITOR_PID=$!
echo $MONITOR_PID > "$PID_FILE"

# Run claude command
log "Running: claude $*"
exec claude "$@"

# Cleanup on exit
kill $MONITOR_PID 2>/dev/null || true
rm -f "$PID_FILE"
WRAPEOF

chmod +x "$REPO_DIR/myclaude-wrapper.sh"
log_info "Wrapper script created at $REPO_DIR/myclaude-wrapper.sh"