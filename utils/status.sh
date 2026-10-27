#!/bin/bash
# MyClaude Status Utility
# Shows status of MyClaude services and health checks
# Port precedence: .nginx_port/.litellm_port (live, written by myclaude.sh on
# every start) > .env (install-time / MYCLAUDE_* pins) > 8000/8001 last resort.

# set -uo pipefail, NOT -e. This is a REPORTING tool: every check_* function
# returns 1 to signal "this is broken", and main() calls them bare. Under `set -e`
# the script aborted at the first bad news it found (and, before 2026-10-27, it
# aborted even earlier: read_ports_from_env's HTTPS_PORT=$(grep …) returns 1 when
# .env has no HTTPS_PORT line, which is every myclaude.sh-managed box -- so the
# tool was dead on arrival and could never print a report at all). A status report
# must never die because something is wrong. -u keeps typos fatal; pipefail keeps
# pipelines honest.

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults
REPO_DIR="${MYCLAUDE_INSTALL_DIR:-$HOME/myclaude}"
SERVICE_NAME="myclaude"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

MyClaude Status Utility

Options:
  --repo-dir DIR       MyClaude installation directory (default: \$HOME/myclaude)
  --live               Show live logs (journalctl -f)
  --help               Show this help

Environment Variables:
  MYCLAUDE_INSTALL_DIR MyClaude installation directory

Examples:
  $0                    # Basic status
  $0 --live             # Live log view
EOF
    exit 1
}

parse_args() {
    LIVE_LOGS=false
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repo-dir) REPO_DIR="$2"; shift 2 ;;
            --live) LIVE_LOGS=true; shift ;;
            --help) usage ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
}

check_service() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "${GREEN}● $service${NC} (running)"
        return 0
    else
        echo -e "${RED}● $service${NC} (stopped)"
        return 1
    fi
}

check_nginx_site() {
    local site="$1"
    if [[ -f "/etc/nginx/sites-enabled/$site" ]]; then
        echo -e "${GREEN}● nginx site $site${NC} (enabled)"
        return 0
    else
        echo -e "${RED}● nginx site $site${NC} (disabled)"
        return 1
    fi
}

check_port() {
    local port="$1"
    local service="$2"
    if ss -tuln | grep -q ":${port} "; then
        echo -e "${GREEN}● Port $port ($service)${NC} (listening)"
        return 0
    else
        echo -e "${RED}● Port $port ($service)${NC} (not listening)"
        return 1
    fi
}

check_health_endpoint() {
    local url="$1"
    local name="$2"
    if curl -s --max-time 5 "$url" >/dev/null 2>&1; then
        echo -e "${GREEN}● $name health${NC} (OK)"
        return 0
    else
        echo -e "${RED}● $name health${NC} (FAILED)"
        return 1
    fi
}

read_ports_from_env() {
    # PRECEDENCE (fixed 2026-10-27). The LIVE ports live in the runtime dot-files
    # myclaude.sh writes on every start (.nginx_port / .litellm_port). .env carries
    # only install-time values / optional MYCLAUDE_* pins and goes stale the moment
    # myclaude re-allocates (observed: 45133 -> 46411 under a running session).
    # Reading .env FIRST made this tool check 8000/8001 against a system on
    # ephemeral ports and print an ALL-RED report on a healthy box. doctor s4 and
    # tests/probe_cancel already read the dot-files; this aligns status.sh.
    NGINX_PORT=""
    LITELLM_PORT=""
    HTTPS_PORT=""

    # 1. Runtime dot-files = the actual live ports (authoritative).
    [[ -f "$REPO_DIR/.nginx_port"   ]] && NGINX_PORT=$(tr -d '[:space:]' < "$REPO_DIR/.nginx_port")
    [[ -f "$REPO_DIR/.litellm_port" ]] && LITELLM_PORT=$(tr -d '[:space:]' < "$REPO_DIR/.litellm_port")

    # 2. .env = install-time values or explicit pins (fallback). Matches BOTH the
    #    current install.sh name (NGINX_PORT) and the post-B1 pin name
    #    (MYCLAUDE_NGINX_PORT) so this tool is correct before AND after B1 lands.
    local env_file="$REPO_DIR/.env"
    if [[ -f "$env_file" ]]; then
        [[ -z "$NGINX_PORT"   ]] && NGINX_PORT=$(grep -E '^(MYCLAUDE_)?NGINX_PORT='   "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | sed "s/^[\"']//; s/[\"']$//")
        [[ -z "$LITELLM_PORT" ]] && LITELLM_PORT=$(grep -E '^(MYCLAUDE_)?LITELLM_PORT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | sed "s/^[\"']//; s/[\"']$//")
        HTTPS_PORT=$(grep -E '^HTTPS_PORT=' "$env_file" 2>/dev/null | head -1 | cut -d= -f2 | sed "s/^[\"']//; s/[\"']$//")
    fi

    # 3. Last-resort guess (the caller prints these as the ports it checked).
    NGINX_PORT="${NGINX_PORT:-8000}"
    LITELLM_PORT="${LITELLM_PORT:-8001}"
    HTTPS_PORT="${HTTPS_PORT:-}"
}

show_recent_logs() {
    local service="$1"
    local lines="${2:-20}"
    echo
    echo -e "${CYAN}Recent $service logs (last $lines lines):${NC}"
    if [[ -f "$REPO_DIR/guard.log" ]]; then
        echo -e "${YELLOW}Guard logs (concurrency_guard evidence):${NC}"
        tail -n "$lines" "$REPO_DIR/guard.log" || true
    fi
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo -e "${YELLOW}Systemd logs:${NC}"
        journalctl -u "$service" -n "$lines" --no-pager 2>/dev/null || true
    fi
}

print_header() {
    echo
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}           MyClaude Status Report${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${CYAN}Installation Directory:${NC} $REPO_DIR"
}

print_summary() {
    echo
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}              Status Check Complete${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}Useful commands:${NC}"
    echo "  $0 --live          # View live logs"
    echo "  myclaude           # Launch Claude Code via proxy"
    echo "  sudo journalctl -u $SERVICE_NAME -f  # Follow service logs"
    echo "  sudo $REPO_DIR/uninstall.sh  # Uninstall MyClaude"
    echo
}

main() {
    parse_args "$@"
    print_header

    # Read ports from .env (dynamic)
    read_ports_from_env

    # Service status
    echo -e "${CYAN}Services:${NC}"
    check_service "$SERVICE_NAME"
    check_service "nginx"
    echo

    # Site status
    echo -e "${CYAN}Nginx Sites:${NC}"
    check_nginx_site "myclaude"
    echo

    # Port status (from .env, not hardcoded)
    echo -e "${CYAN}Ports:${NC}"
    check_port "${NGINX_PORT}" "Nginx HTTP"
    check_port "${LITELLM_PORT}" "LiteLLM"
    if [[ -n "$HTTPS_PORT" ]]; then
        check_port "$HTTPS_PORT" "HTTPS"
    fi
    echo

    # Health checks (from .env, not hardcoded)
    echo -e "${CYAN}Health Checks:${NC}"
    check_health_endpoint "http://localhost:${NGINX_PORT}/health" "Nginx"
    check_health_endpoint "http://localhost:${LITELLM_PORT}/health/liveliness" "LiteLLM (liveliness)"

# (No authenticated /health probe here on purpose: /health makes model test-calls
#  to every deployment = NVIDIA quota + burst; and the old "with auth" check sent
#  no header, so it only produced guard post_call_failure noise. liveliness above
#  is the clean backend check; doctor s5/s6 own authenticated/model probing.)
    echo

    # Configuration files
    echo -e "${CYAN}Configuration Files:${NC}"
    [[ -f "$REPO_DIR/.env" ]] && echo -e "${GREEN}● ${REPO_DIR}/.env${NC}" || echo -e "${RED}● ${REPO_DIR}/.env${NC} (missing)"
    [[ -f "$REPO_DIR/config.yaml" ]] && echo -e "${GREEN}● ${REPO_DIR}/config.yaml${NC}" || echo -e "${RED}● ${REPO_DIR}/config.yaml${NC} (missing)"
    [[ -f "$REPO_DIR/requirements.txt" ]] && echo -e "${GREEN}● ${REPO_DIR}/requirements.txt${NC}" || echo -e "${RED}● ${REPO_DIR}/requirements.txt${NC} (missing)"
    echo

    # Show logs if requested
    if [[ "$LIVE_LOGS" == true ]]; then
        echo -e "${CYAN}Live Logs (Press Ctrl+C to exit):${NC}"
        if [[ -f "$REPO_DIR/guard.log" ]]; then
            tail -f "$REPO_DIR/guard.log" &
            TAIL_PID=$!
        fi
        if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
            journalctl -u "$SERVICE_NAME" -f &
            JOURNAL_PID=$!
        fi
        # Wait for user to interrupt
        wait $TAIL_PID $JOURNAL_PID 2>/dev/null || true
    else
        show_recent_logs "$SERVICE_NAME" 10
    fi

    print_summary
}

main "$@"