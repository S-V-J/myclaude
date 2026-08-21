#!/bin/bash
# MyClaude Driver — Programmatic interaction harness for the MyClaude proxy stack
# Location: .claude/skills/run-myclaude/driver.sh
# Usage: ./driver.sh <command> [args...]

set -euo pipefail

REPO_DIR="/home/ML/myclaude"
SERVICE_NAME="myclaude"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"
PROXY_URL="http://localhost:4000"
LITELLM_URL="http://localhost:4001"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }

# Load local proxy key from .env
load_env() {
    if [ -f "$REPO_DIR/.env" ]; then
        export LITELLM_MASTER_KEY=$(grep "LITELLM_MASTER_KEY" "$REPO_DIR/.env" | cut -d'"' -f2)
        export NVIDIA_API_KEY_PROJECT_1=$(grep "NVIDIA_API_KEY_PROJECT_1" "$REPO_DIR/.env" | cut -d'"' -f2)
        export NVIDIA_API_KEY_PROJECT_2=$(grep "NVIDIA_API_KEY_PROJECT_2" "$REPO_DIR/.env" | cut -d'"' -f2)
        export NVIDIA_API_KEY_PROJECT_3=$(grep "NVIDIA_API_KEY_PROJECT_3" "$REPO_DIR/.env" | cut -d'"' -f2)
        export NVIDIA_API_KEY_PROJECT_4=$(grep "NVIDIA_API_KEY_PROJECT_4" "$REPO_DIR/.env" | cut -d'"' -f2)
        export MYCLAUDE_IDLE_TIMEOUT=$(grep "MYCLAUDE_IDLE_TIMEOUT" "$REPO_DIR/.env" | cut -d'=' -f2)
    fi
    # Defaults
    LITELLM_MASTER_KEY="${LITELLM_MASTER_KEY:-sk-local-proxy-key}"
    MYCLAUDE_IDLE_TIMEOUT="${MYCLAUDE_IDLE_TIMEOUT:-300}"
}

# Check if service is running
is_service_active() {
    systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null
}

# Check if port is listening
is_port_listening() {
    local port="$1"
    ss -tlnp 2>/dev/null | grep -q ":$port "
}

# Wait for health endpoint
wait_for_health() {
    local url="$1"
    local max_wait="${2:-30}"
    local waited=0

    log_info "Waiting for $url to become healthy..."
    while [ $waited -lt $max_wait ]; do
        if curl -s --max-time 2 -f "$url" >/dev/null 2>&1; then
            log_success "$url is healthy"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
        echo -n "."
    done
    echo ""
    log_error "Health check timeout after ${max_wait}s for $url"
    return 1
}

# Start backend via myclaude wrapper (on-demand)
cmd_start() {
    load_env
    log_info "Starting MyClaude backend (on-demand)..."

    if is_service_active; then
        log_info "Backend already running"
        return 0
    fi

    # Use the wrapper's start logic (it handles retries and health checks)
    timeout 60 /usr/local/bin/myclaude "ping" 2>&1 || true

    # Verify
    if wait_for_health "$PROXY_URL/health" 30; then
        log_success "MyClaude backend started successfully"
        cmd_status
    else
        log_error "Failed to start backend"
        journalctl -u "$SERVICE_NAME" -n 20 --no-pager
        return 1
    fi
}

# Stop backend gracefully
cmd_stop() {
    log_info "Stopping MyClaude backend..."
    sudo systemctl stop "$SERVICE_NAME"
    log_success "MyClaude backend stopped"
}

# Show status
cmd_status() {
    load_env
    echo "=== MyClaude Status ==="
    echo ""

    # Systemd status
    if is_service_active; then
        log_success "Service: ACTIVE"
    else
        log_error "Service: INACTIVE"
    fi

    # Port checks
    if is_port_listening 4000; then
        log_success "nginx (port 4000): LISTENING"
    else
        log_error "nginx (port 4000): NOT LISTENING"
    fi

    if is_port_listening 4001; then
        log_success "LiteLLM (port 4001): LISTENING"
    else
        log_error "LiteLLM (port 4001): NOT LISTENING"
    fi

    if is_port_listening 4443; then
        log_success "nginx HTTPS (port 4443): LISTENING"
    else
        log_info "nginx HTTPS (port 4443): NOT LISTENING (TLS disabled)"
    fi

    # Process info
    echo ""
    echo "=== Processes ==="
    ps aux | grep -E "[l]itellm|[n]ginx: worker|[m]yclaude" | head -10 || true

    # Memory usage
    echo ""
    echo "=== Memory Usage ==="
    local mem_mb
    mem_mb=$(ps aux | awk '/[l]itellm|[n]ginx: worker/ {sum+=$6} END {print sum/1024}' 2>/dev/null || echo "0")
    echo "Total RAM: ${mem_mb} MB"

    # Config info
    echo ""
    echo "=== Config ==="
    echo "Idle timeout: ${MYCLAUDE_IDLE_TIMEOUT}s"
    if [ -f "$REPO_DIR/.env" ]; then
        local keys_set=0
        for i in 1 2 3 4; do
            local key_var="NVIDIA_API_KEY_PROJECT_$i"
            if [ -n "${!key_var:-}" ] && [ "${!key_var:-}" != "nvapi-..." ]; then
                ((keys_set++))
            fi
        done
        echo "API keys configured: $keys_set/4"
    fi
}

# Quick health check
cmd_health() {
    load_env
    echo "=== Health Checks ==="

    # nginx health (no auth)
    echo -n "nginx /health (port 4000): "
    if curl -s --max-time 5 "$PROXY_URL/health" | grep -q "healthy"; then
        log_success "OK"
    else
        log_error "FAILED"
    fi

    # LiteLLM health (requires auth, optional)
    echo -n "LiteLLM /health (port 4001): "
    if curl -s --max-time 5 -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$LITELLM_URL/health" | grep -q "healthy"; then
        log_success "OK"
    else
        log_warn "Not available (requires auth, optional)"
    fi
}

# Test all 4 models
cmd_test() {
    load_env
    log_info "Testing all 4 models via proxy at $PROXY_URL"

    declare -A MODELS=(
        ["claude-opus-5"]="PROJECT_1"
        ["claude-sonnet-5"]="PROJECT_2"
        ["claude-sonnet-5-1m"]="PROJECT_3"
        ["claude-haiku-4-5"]="PROJECT_4"
    )

    local passed=0
    local failed=0

    for model in "${!MODELS[@]}"; do
        local project="${MODELS[$model]}"
        echo -n "Testing $model (Nemotron 3 Ultra, $project)... "

        local response
        response=$(curl -s --max-time 30 \
            -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
            -H "Content-Type: application/json" \
            -X POST "$PROXY_URL/v1/chat/completions" \
            -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word\"}],\"max_tokens\":20}" 2>&1) || true

        if echo "$response" | grep -q '"choices"'; then
            local content
            content=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    choices = data.get('choices', [])
    if choices:
        msg = choices[0].get('message', {})
        content = msg.get('content', '')
        if isinstance(content, list):
            for c in content:
                if c.get('type') == 'text':
                    print(c.get('text', '')[:50])
                    break
        else:
            print(content[:50])
except:
    pass
" 2>/dev/null)
            log_success "$model - Response: ${content:-'(empty)'}"
            ((passed++))
        elif echo "$response" | grep -q '"error"'; then
            local error_msg
            error_msg=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    err = data.get('error', {})
    print(err.get('message', str(err))[:80])
except:
    pass
" 2>/dev/null)
            log_fail "$model - Error: ${error_msg:-'$response'}"
            ((failed++))
        else
            log_fail "$model - Unexpected response: ${response:0:80}"
            ((failed++))
        fi
    done

    echo ""
    log_info "Results: $passed passed, $failed failed"

    if [ $failed -eq 0 ]; then
        log_success "All models working! (Nemotron 3 Ultra with 4 independent API keys)"
        return 0
    else
        log_error "Some models failed"
        return 1
    fi
}

# Single model curl
cmd_curl() {
    load_env
    local model="${1:-claude-opus-5}"
    local prompt="${2:-Say hello in one word}"

    log_info "Calling $model with prompt: $prompt"

    local response
    response=$(curl -s --max-time 60 \
        -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        -H "Content-Type: application/json" \
        -X POST "$PROXY_URL/v1/chat/completions" \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"$prompt\"}],\"max_tokens\":100}" 2>&1)

    if echo "$response" | grep -q '"choices"'; then
        local content
        content=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    choices = data.get('choices', [])
    if choices:
        msg = choices[0].get('message', {})
        content = msg.get('content', '')
        if isinstance(content, list):
            for c in content:
                if c.get('type') == 'text':
                    print(c.get('text', ''))
                    break
        else:
            print(content)
except Exception as e:
    print(f'Parse error: {e}')
" 2>/dev/null)
        echo "$content"
    else
        log_error "Request failed:"
        echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    err = data.get('error', {})
    print(f\"  {err.get('message', str(err))}\")
except:
    print(sys.stdin.read()[:200])
"
        return 1
    fi
}

# Tail logs
cmd_logs() {
    log_info "Tailing myclaude logs (Ctrl-C to exit)..."
    sudo journalctl -u "$SERVICE_NAME" -f
}

# Show config
cmd_config() {
    load_env
    echo "=== MyClaude Configuration ==="
    echo ""
    echo "Repo: $REPO_DIR"
    echo "Service: $SERVICE_NAME"
    echo "Proxy URL: $PROXY_URL"
    echo "LiteLLM URL: $LITELLM_URL"
    echo "Idle timeout: ${MYCLAUDE_IDLE_TIMEOUT}s"
    echo ""
    echo "API Keys (from .env):"
    for i in 1 2 3 4; do
        local key_var="NVIDIA_API_KEY_PROJECT_$i"
        local val="${!key_var:-}"
        if [ -n "$val" ] && [ "$val" != "nvapi-..." ]; then
            echo "  PROJECT_$i: ${val:0:12}... (set)"
        else
            echo "  PROJECT_$i: (not set, falls back to PROJECT_1)"
        fi
    done
    echo ""
    echo "Local proxy key: ${LITELLM_MASTER_KEY:0:12}..."
    echo ""
    echo "Models (from config.yaml):"
    if [ -f "$REPO_DIR/config.yaml" ]; then
        grep "model_name:" "$REPO_DIR/config.yaml" | sed 's/.*model_name: /  - /'
    fi
    echo ""
    echo "TLS:"
    if grep -q "listen 4443" "$NGINX_CONF" 2>/dev/null; then
        echo "  ENABLED (port 4443)"
        local cert="/etc/ssl/myclaude/myclaude.crt"
        if [ -f "$cert" ]; then
            echo "  Cert: $cert"
            openssl x509 -in "$cert" -noout -subject -dates 2>/dev/null | sed 's/^/    /'
        fi
    else
        echo "  DISABLED (HTTP only on port 4000)"
    fi
}

# Enable TLS
cmd_tls_enable() {
    local domain="${1:-localhost}"
    log_info "Enabling TLS for domain: $domain"
    bash "$REPO_DIR/setup-tls.sh" generate "$domain" true
    log_success "TLS enabled. Run 'driver.sh health' to verify."
}

# Disable TLS
cmd_tls_disable() {
    log_info "Disabling TLS..."
    bash "$REPO_DIR/setup-tls.sh" disable
    log_success "TLS disabled. HTTP-only on port 4000."
}

# Help
cmd_help() {
    cat <<EOF
MyClaude Driver — Programmatic interaction harness

Usage: ./driver.sh <command> [args...]

Commands:
  start                    Start backend (on-demand), wait for health
  stop                     Stop backend gracefully
  status                   Show service, port, process, and memory status
  health                   Quick health check (nginx + LiteLLM /health)
  test                     Run full model test suite (all 4 models)
  curl <model> "<prompt>"  Send chat completion to specific model
  logs                     Tail journalctl logs (live)
  config                   Show current configuration
  tls-enable <domain>      Enable HTTPS via setup-tls.sh
  tls-disable              Disable HTTPS, restore HTTP-only
  help                     Show this help

Examples:
  ./driver.sh start
  ./driver.sh health
  ./driver.sh test
  ./driver.sh curl claude-opus-5 "Explain quantum computing"
  ./driver.sh curl claude-sonnet-5 "Write a haiku"
  ./driver.sh status
  ./driver.sh logs
  ./driver.sh config
  ./driver.sh tls-enable myclaude.local
  ./driver.sh tls-disable

Models: claude-opus-5, claude-sonnet-5, claude-sonnet-5-1m, claude-haiku-4-5
All route to Nemotron 3 Ultra with different API keys for load isolation.
EOF
}

# Main
main() {
    local cmd="${1:-help}"
    shift || true

    case "$cmd" in
        start) cmd_start ;;
        stop) cmd_stop ;;
        status) cmd_status ;;
        health) cmd_health ;;
        test) cmd_test ;;
        curl) cmd_curl "$@" ;;
        logs) cmd_logs ;;
        config) cmd_config ;;
        tls-enable) cmd_tls_enable "$@" ;;
        tls-disable) cmd_tls_disable ;;
        help|--help|-h) cmd_help ;;
        *) log_error "Unknown command: $cmd"; cmd_help; exit 1 ;;
    esac
}

main "$@"