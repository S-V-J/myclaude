#!/bin/bash
# ============================================================
# MyClaude - Modular One-Command Installation
# ============================================================
# Usage: bash install-modular.sh [--auto] [--no-claude] [--docker]
# ============================================================

set -euo pipefail

# ============================================================
# MODULE SYSTEM
# ============================================================

MODULES_DIR="$(dirname "$0")/install-modules"
MODULES=(
    "01-detect-os"
    "02-install-packages"
    "03-setup-user"
    "04-setup-venv"
    "05-write-env"
    "06-setup-nginx"
    "07-setup-systemd"
    "08-setup-logrotate"
    "09-setup-wrapper"
    "10-setup-claude-code"
    "11-setup-claude-settings"
    "12-setup-bashrc"
    "13-verify"
)

# Load all modules
for module in "${MODULES[@]}"; do
    if [[ -f "$MODULES_DIR/$module.sh" ]]; then
        # shellcheck source=/dev/null
        source "$MODULES_DIR/$module.sh"
    else
        echo "ERROR: Module not found: $MODULES_DIR/$module.sh" >&2
        exit 1
    fi
done

# Load TUI helpers
# shellcheck source=/dev/null
source "$MODULES_DIR/tui-helpers.sh"

# ============================================================
# MAIN INSTALLER
# ============================================================

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVICE_NAME="myclaude"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"
VENV_DIR="$REPO_DIR/venv"
SERVICE_USER="myclaude"
CLAUDE_SETTINGS_DIR="$HOME/.claude"
CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"

# Global config (can be overridden by --auto env vars)
NVIDIA_API_KEY_PROJECT_1="${NVIDIA_API_KEY_PROJECT_1:-}"
NVIDIA_API_KEY_PROJECT_2="${NVIDIA_API_KEY_PROJECT_2:-}"
NVIDIA_API_KEY_PROJECT_3="${NVIDIA_API_KEY_PROJECT_3:-}"
NVIDIA_API_KEY_PROJECT_4="${NVIDIA_API_KEY_PROJECT_4:-}"
ENABLE_LAN="${ENABLE_LAN:-false}"
ENABLE_TLS="${ENABLE_TLS:-false}"
TLS_DOMAIN="${TLS_DOMAIN:-localhost}"
TLS_ENABLE_HTTP="${TLS_ENABLE_HTTP:-true}"
NGINX_RATE="${NGINX_RATE:-50}"
NGINX_BURST="${NGINX_BURST:-100}"
REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-3600}"
INSTALL_CLAUDE="${INSTALL_CLAUDE:-true}"
USE_DOCKER="${USE_DOCKER:-false}"

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

# ============================================================
# HELP
# ============================================================

show_help() {
    cat <<'HELPEOF'
MyClaude Modular Installer

USAGE:
    bash install-modular.sh [OPTIONS]

OPTIONS:
    --auto              Non-interactive mode (uses env vars)
    --no-claude         Skip Claude Code installation
    --docker            Install Docker deployment instead of native
    --help              Show this help

ENVIRONMENT VARIABLES (for --auto):
    NVIDIA_API_KEY_PROJECT_1    Required: Primary NVIDIA NIM API key
    NVIDIA_API_KEY_PROJECT_2    Optional: Second API key
    NVIDIA_API_KEY_PROJECT_3    Optional: Third API key
    NVIDIA_API_KEY_PROJECT_4    Optional: Fourth API key
    ENABLE_LAN                  Enable LAN access (default: false)
    ENABLE_TLS                  Enable TLS/SSL (default: false)
    TLS_DOMAIN                  Domain for TLS cert (default: localhost)
    TLS_ENABLE_HTTP             Keep HTTP on 4000 (default: true)
    NGINX_RATE                  Nginx rate limit req/s (default: 50)
    NGINX_BURST                 Nginx burst limit (default: 100)
    REQUEST_TIMEOUT             Request timeout seconds (default: 3600)
    INSTALL_CLAUDE              Install Claude Code (default: true)

EXAMPLES:
    # Interactive TUI
    bash install-modular.sh

    # Auto mode with single API key
    NVIDIA_API_KEY_PROJECT_1=nvapi-xxx bash install-modular.sh --auto

    # Auto mode with all options
    NVIDIA_API_KEY_PROJECT_1=nvapi-xxx \
    NVIDIA_API_KEY_PROJECT_2=nvapi-yyy \
    ENABLE_LAN=true \
    ENABLE_TLS=true \
    TLS_DOMAIN=myclaude.local \
    bash install-modular.sh --auto

    # Docker deployment
    bash install-modular.sh --docker

    # Skip Claude Code (already installed)
    bash install-modular.sh --no-claude

HELPEOF
}

# ============================================================
# TUI / INTERACTIVE MODE
# ============================================================

run_interactive() {
    # Check for whiptail/dialog
    if ! command -v whiptail &>/dev/null && ! command -v dialog &>/dev/null; then
        log_warn "No TUI tool found (whiptail/dialog). Installing packages first..."
        install_system_packages
    fi

    if command -v whiptail &>/dev/null; then
        TUI_TOOL="whiptail"
    elif command -v dialog &>/dev/null; then
        TUI_TOOL="dialog"
    else
        log_error "Cannot run interactive mode without whiptail or dialog"
        exit 1
    fi

    # Step 1: API Keys
    if ! step1_api_keys; then
        exit 1
    fi

    # Step 2: Advanced Options
    step3_advanced

    # Step 3: Confirm
    if ! confirm_installation; then
        echo "Installation cancelled."
        exit 0
    fi
}

confirm_installation() {
    local msg="Ready to install MyClaude?\n\nThis will:\n"
    msg+="• Install system packages (nginx, python3-venv, etc.)\n"
    msg+="• Create system user '$SERVICE_USER'\n"
    msg+="• Set up Python venv + LiteLLM\n"
    msg+="• Configure nginx (worker_processes=1 for on-demand)\n"
    msg+="• Configure systemd service (Restart=on-failure)\n"
    msg+="• Install myclaude wrapper command\n"

    if [ "$INSTALL_CLAUDE" = true ]; then
        msg+="• Install Claude Code CLI (if missing)\n"
    fi

    msg+="• Create ~/.claude/settings.json (MCP servers, permissions, Opus 1M)\n"
    msg+="• Enable on-demand mode (idle timeout: 5 min)\n"

    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --yesno "$msg" 20 70
    else
        dialog --title "MyClaude Installer" --yesno "$msg" 20 70
    fi
}

# ============================================================
# RUN INSTALLATION
# ============================================================

run_installation() {
    local step=0
    local total=${#MODULES[@]}

    for module in "${MODULES[@]}"; do
        step=$((step + 1))
        local module_name=$(echo "$module" | cut -d- -f2-)
        log_info "[$step/$total] Running module: $module_name"

        # Call module's run function
        local run_func="run_${module//-/_}"
        if declare -f "$run_func" >/dev/null; then
            $run_func
        else
            log_error "Module $module has no run function"
            exit 1
        fi
    done

    log_success "Installation complete!"
    show_post_install
}

show_post_install() {
    cat <<'EOF'

==========================================
MyClaude Installation Complete!
==========================================

Quick Start:
  myclaude              # Launch Claude Code via NVIDIA NIM proxy (on-demand)
  myclaude --help       # Pass args to Claude Code

On-Demand Features:
  • Backend starts automatically when you run 'myclaude'
  • Backend stops after 5 minutes of inactivity
  • Set MYCLAUDE_IDLE_TIMEOUT=0 in .env to disable (always-on)
  • Low memory when idle (~10 MB nginx only)

Service Management:
  sudo systemctl status myclaude
  sudo systemctl restart myclaude
  journalctl -u myclaude -f

Convenience Aliases (run 'source ~/.bashrc'):
  myclaude-status  myclaude-logs  myclaude-start  myclaude-stop

Claude Code Configured With:
  • ~/.claude/settings.json (MCP servers, permissions, Opus 1M)
  • Auto-detects TLS (HTTPS on 4443 if enabled)

Files Created:
  /usr/local/bin/myclaude       # Main wrapper command
  /etc/systemd/system/myclaude.service
  /etc/nginx/sites-enabled/myclaude
  /home/ML/myclaude/.env        # API keys + config
  ~/.claude/settings.json       # Claude Code settings

EOF
}

# ============================================================
# ENTRY POINT
# ============================================================

main() {
    # Parse args
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --auto) AUTO_MODE=true ;;
            --no-claude) INSTALL_CLAUDE=false ;;
            --docker) USE_DOCKER=true ;;
            --help) show_help; exit 0 ;;
            *) log_error "Unknown option: $1"; show_help; exit 1 ;;
        esac
        shift
    done

    if [ "$USE_DOCKER" = true ]; then
        log_info "Docker deployment mode"
        exec bash "$REPO_DIR/docker/deploy.sh"
    fi

    cd "$REPO_DIR"

    if [[ "${AUTO_MODE:-false}" == "true" ]]; then
        if [ -z "$NVIDIA_API_KEY_PROJECT_1" ]; then
            log_error "NVIDIA_API_KEY_PROJECT_1 required for --auto mode"
            exit 1
        fi
        # Skip TUI, just run modules
        install_system_packages
        run_installation
    else
        # Interactive TUI
        if ! whiptail --title "MyClaude Installer" --yesno "Welcome to MyClaude Installer\n\nThis will set up:\n• nginx reverse proxy (port 4000/4443)\n• LiteLLM proxy (port 4001)\n• NVIDIA NIM model routing (4 models)\n• systemd service with auto-restart\n• myclaude command wrapper\n• Claude Code CLI (if not installed)\n• ~/.claude/settings.json (MCP servers, permissions, Opus 1M)\n\nContinue?" 20 70; then
            exit 0
        fi
        run_interactive
        run_installation
    fi
}

main "$@"