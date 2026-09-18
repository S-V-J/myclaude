#!/bin/bash
# MyClaude One-Command Installation Script
# Fully automated installation - installs dependencies, configures services, and starts everything
# Run with: sudo ./install.sh [options]

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Defaults - can be overridden by environment variables or command line
INSTALL_DIR="${MYCLAUDE_INSTALL_DIR:-$HOME/myclaude}"
SERVICE_USER="${MYCLAUDE_SERVICE_USER:-$USER}"
ENABLE_HTTPS="${MYCLAUDE_ENABLE_HTTPS:-false}"
TLS_DOMAIN="${MYCLAUDE_TLS_DOMAIN:-}"
AUTO_INSTALL_DEPS="${MYCLAUDE_AUTO_INSTALL_DEPS:-true}"

# Paths for searches
NGINX_CONF="/etc/nginx/sites-available"
LITELLM_SERVICE_FILE="/etc/systemd/system"

# Will be discovered dynamically
NGINX_PORT=""
LITELLM_PORT=""
HTTPS_PORT=""

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

MyClaude One-Command Installation System

Options:
  --dir DIR              Installation directory (default: \$HOME/myclaude)
  --user USER            Service user (default: current user)
  --https                Enable HTTPS/TLS
  --domain DOMAIN        TLS domain name (required with --https)
  --no-deps              Skip automatic dependency installation
  --help                 Show this help

Environment Variables:
  MYCLAUDE_INSTALL_DIR   Installation directory
  MYCLAUDE_SERVICE_USER  Service user
  MYCLAUDE_ENABLE_HTTPS  Enable HTTPS (true/false)
  MYCLAUDE_TLS_DOMAIN    TLS domain name
  MYCLAUDE_AUTO_INSTALL_DEPS  Auto install dependencies (true/false)

Note: This script automatically installs dependencies, discovers free ports,
      configures services, and starts everything. After installation,
      you need to add your NVIDIA API keys to $INSTALL_DIR/.env

Examples:
  $0                                    # One-command install (with deps)
  $0 --no-deps                          # Skip dependency install (if already done)
  $0 --dir /opt/myclaude --user myclaude
  $0 --https --domain api.example.com   # With HTTPS
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dir) INSTALL_DIR="$2"; shift 2 ;;
            --user) SERVICE_USER="$2"; shift 2 ;;
            --https) ENABLE_HTTPS="true"; shift ;;
            --domain) TLS_DOMAIN="$2"; shift 2 ;;
            --no-deps) AUTO_INSTALL_DEPS="false"; shift ;;
            --help) usage ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        log_info "For one-command install, run: sudo $0 $*"
        exit 1
    fi
}

install_dependencies() {
    if [[ "$AUTO_INSTALL_DEPS" == "false" ]]; then
        log_info "Skipping dependency installation (--no-deps flag used)"
        return 0
    fi

    log_info "Installing system dependencies..."

    # Update package list
    apt-get update -qq >/dev/null 2>&1

    # Install required packages
    local deps=(nginx python3 python3-venv curl jq procps)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! dpkg -l | grep -q "^ii  $dep"; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Installing missing dependencies: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" >/dev/null 2>&1
        log_success "Dependencies installed"
    else
        log_success "All dependencies already installed"
    fi

    # Install certbot if HTTPS is enabled
    if [[ "$ENABLE_HTTPS" == "true" ]]; then
        if ! dpkg -l | grep -q "^ii  certbot"; then
            log_info "Installing certbot for HTTPS..."
            DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx >/dev/null 2>&1
            log_success "certbot installed"
        fi
    fi
}

check_existing_installation() {
    if [[ -d "$INSTALL_DIR" && "$(ls -A "$INSTALL_DIR")" ]]; then
        log_warn "Installation directory $INSTALL_DIR is not empty"
        read -rp "Continue anyway? (y/N) " -n 1
        echo
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            log_info "Installation cancelled"
            exit 1
        fi
    fi
}

create_directories() {
    log_info "Creating directories..."
    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/venv"
    mkdir -p "$INSTALL_DIR/logs"
    mkdir -p /var/log/nginx
    log_success "Directories created"
}

discover_ports() {
    log_info "Discovering free ports..."

    # Find nginx port - check 8000-50000 range
    NGINX_PORT=""
    for ((port=8000; port<=50000; port++)); do
        if ! ss -tuln | grep -q ":${port} "; then
            NGINX_PORT=$port
            break
        fi
    done

    if [[ -z "$NGINX_PORT" ]]; then
        log_error "Could not find free nginx port in 8000-50000 range"
        exit 1
    fi
    log_info "Nginx port: $NGINX_PORT"

    # LiteLLM needs to be close to nginx but different
    LITELLM_PORT=$((NGINX_PORT + 1))
    if ss -tuln | grep -q ":${LITELLM_PORT} "; then
        # Find next available port
        for ((port=LITELLM_PORT+1; port<=50000; port++)); do
            if ! ss -tuln | grep -q ":${port} "; then
                LITELLM_PORT=$port
                break
            fi
        done
    fi

    log_info "LiteLLM port: $LITELLM_PORT"

    # HTTPS port - separate from the above
    HTTPS_PORT=""
    if [[ "$ENABLE_HTTPS" == "true" ]]; then
        for ((port=8443; port<=50000; port++)); do  # Start from 8443 for HTTPS
            if ! ss -tuln | grep -q ":${port} "; then
                HTTPS_PORT=$port
                break
            fi
        done
        if [[ -z "$HTTPS_PORT" ]]; then
            log_error "Could not find free HTTPS port"
            exit 1
        fi
        log_info "HTTPS port: $HTTPS_PORT"
    fi

    log_success "Ports discovered: nginx=$NGINX_PORT, litellm=$LITELLM_PORT, https=${HTTPS_PORT:-not-enabled}"
}

install_python_deps() {
    log_info "Setting up Python virtual environment..."
    python3 -m venv "$INSTALL_DIR/venv"
    "$INSTALL_DIR/venv/bin/pip" install --upgrade pip >/dev/null 2>&1
    "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" >/dev/null 2>&1
    log_success "Python dependencies installed"
}

generate_env_file() {
    log_info "Generating .env file with discovered ports..."

    # Generate a random master key
    local master_key
    master_key="sk-local-$(openssl rand -hex 32)"

    cat > "$INSTALL_DIR/.env" <<EOF
# MyClaude Environment Configuration
# Ports dynamically assigned at installation to avoid conflicts
# IMPORTANT: Replace the placeholder NVIDIA API keys below with your actual keys

# NVIDIA API Keys (REQUIRED - get from https://build.nvidia.com/)
NVIDIA_API_KEY_1="nvapi-placeholder-replace-with-your-key-1"
NVIDIA_API_KEY_2="nvapi-placeholder-replace-with-your-key-2"
NVIDIA_API_KEY_3="nvapi-placeholder-replace-with-your-key-3"
NVIDIA_API_KEY_4="nvapi-placeholder-replace-with-your-key-4"

# LiteLLM Master Key (generated automatically)
LITELLM_MASTER_KEY="$master_key"

# LiteLLM Settings
LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="true"

# Idle Timeout (0 = always on, seconds otherwise)
IDLE_TIMEOUT="0"

# Dynamic ports (do not edit manually)
LITELLM_PORT=${LITELLM_PORT}
NGINX_PORT=${NGINX_PORT}
HTTPS_PORT=${HTTPS_PORT:-}

# After installation:
# 1. Edit this file and replace the placeholder NVIDIA API keys with your actual keys
# 2. Run: sudo systemctl restart myclaude
# 3. Test with: myclaude
EOF
    log_success ".env file created at $INSTALL_DIR/.env"
    log_warn "NEXT STEP: Edit $INSTALL_DIR/.env and add your actual NVIDIA API keys"
}

build_config() {
    log_info "Building LiteLLM config.yaml..."
    cd "$INSTALL_DIR"
    ./build_config.sh
    log_success "config.yaml built successfully"
}

install_systemd_service() {
    log_info "Installing systemd service from template..."

    # Check if template exists
    if [[ ! -f "${INSTALL_DIR}/litellm.service.template" ]]; then
        log_error "litellm.service.template not found in ${INSTALL_DIR}"
        exit 1
    fi

    # Process template with actual values
    sed -e "s|__SERVICE_USER__|${SERVICE_USER}|g" \
        -e "s|__REPO_DIR__|${INSTALL_DIR}|g" \
        -e "s|__VENV_DIR__|${INSTALL_DIR}/venv|g" \
        -e "s|__PORT__|${LITELLM_PORT}|g" \
        "${INSTALL_DIR}/litellm.service.template" > /etc/systemd/system/myclaude.service

    systemctl daemon-reload
    log_success "Systemd service installed on port ${LITELLM_PORT}"
}

install_nginx_config() {
    log_info "Installing Nginx configuration..."
    sed -e "s|__NGINX_PORT__|${NGINX_PORT}|g" \
        -e "s|__LITELLM_PORT__|${LITELLM_PORT}|g" \
        "$INSTALL_DIR/nginx-myclaude.conf" > /tmp/myclaude-nginx.conf
    cp /tmp/myclaude-nginx.conf /etc/nginx/sites-available/myclaude
    ln -sf /etc/nginx/sites-available/myclaude /etc/nginx/sites-enabled/myclaude

    # Add rate limit zone to nginx.conf if not present
    if ! grep -q "limit_req_zone.*myclaude" /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=myclaude:10m rate=16r/s;' /etc/nginx/nginx.conf
    fi

    nginx -t && systemctl reload nginx
    log_success "Nginx configured on port ${NGINX_PORT}"
}

install_logrotate() {
    log_info "Installing logrotate configuration..."
    sed -e "s|__REPO_DIR__|$INSTALL_DIR|g" \
        -e "s|__SERVICE_USER__|$SERVICE_USER|g" \
        "$INSTALL_DIR/logrotate-myclaude" > /etc/logrotate.d/myclaude
    log_success "Logrotate configuration installed"
}

setup_https() {
    if [[ "$ENABLE_HTTPS" != "true" ]]; then
        return 0
    fi

    if [[ -z "$TLS_DOMAIN" ]]; then
        log_error "--domain is required when using --https"
        exit 1
    fi

    log_info "Setting up HTTPS with Let's Encrypt for $TLS_DOMAIN..."

    if ! command -v certbot >/dev/null 2>&1; then
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y certbot python3-certbot-nginx >/dev/null 2>&1
    fi

    certbot --nginx -d "$TLS_DOMAIN" --non-interactive --agree-tos --email "admin@$TLS_DOMAIN" --redirect

    # Update nginx config for HTTPS
    sed -i "s|__NGINX_HTTPS_PORT__|${HTTPS_PORT}|g" /etc/nginx/sites-available/myclaude
    sed -i "s|__TLS_DOMAIN__|${TLS_DOMAIN}|g" /etc/nginx/sites-available/myclaude
    sed -i "s|__REPO_DIR__|${INSTALL_DIR}|g" /etc/nginx/sites-available/myclaude

    nginx -t && systemctl reload nginx
    log_success "HTTPS configured for $TLS_DOMAIN on port ${HTTPS_PORT}"
}

install_launcher() {
    log_info "Installing myclaude launcher..."
    cp "$INSTALL_DIR/myclaude.sh" /usr/local/bin/myclaude
    chmod +x /usr/local/bin/myclaude
    log_success "Launcher installed at /usr/local/bin/myclaude"
}

set_permissions() {
    log_info "Setting permissions..."
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    chmod 750 "$INSTALL_DIR"
    chmod 640 "$INSTALL_DIR/.env"
    chmod 644 "$INSTALL_DIR/config.yaml"
    chmod 755 "$INSTALL_DIR/myclaude.sh"
    chmod 755 "$INSTALL_DIR/build_config.sh"
    log_success "Permissions set"
}

start_services() {
    log_info "Starting services..."
    systemctl enable myclaude
    systemctl start myclaude
    systemctl enable nginx
    systemctl start nginx
    log_success "Services started"
}

verify_installation() {
    log_info "Verifying installation..."
    sleep 3

    if curl -s --max-time 10 "http://localhost:${NGINX_PORT}/health" >/dev/null 2>&1; then
        log_success "Nginx health check passed on port ${NGINX_PORT}"
    else
        log_warn "Nginx health check failed (may need time to start)"
    fi

    local master_key
    master_key=$(grep "LITELLM_MASTER_KEY" "$INSTALL_DIR/.env" | cut -d= -f2 | sed "s/^[\"']//; s/[\"']$//")
    if curl -s --max-time 10 -H "Authorization: Bearer $master_key" "http://localhost:${LITELLM_PORT}/health" >/dev/null 2>&1; then
        log_success "LiteLLM health check passed on port ${LITELLM_PORT}"
    else
        log_warn "LiteLLM health check failed (may need time to start)"
    fi
}

print_summary() {
    echo
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}        MyClaude One-Command Installation Complete!${NC}"
    echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "Installation directory: ${GREEN}$INSTALL_DIR${NC}"
    echo -e "Service user:           ${GREEN}$SERVICE_USER${NC}"
    echo -e "Nginx port:             ${GREEN}$NGINX_PORT${NC}"
    echo -e "LiteLLM port:           ${GREEN}$LITELLM_PORT${NC}"
    if [[ -n "$HTTPS_PORT" ]]; then
        echo -e "HTTPS port:             ${GREEN}$HTTPS_PORT${NC}"
        echo -e "TLS Domain:             ${GREEN}$TLS_DOMAIN${NC}"
    fi
    echo
    echo -e "${YELLOW}NEXT STEPS (REQUIRED):${NC}"
    echo "  1. Edit $INSTALL_DIR/.env and replace placeholder NVIDIA API keys with your actual keys"
    echo "  2. Get keys from: https://build.nvidia.com/"
    echo "  3. Run: sudo systemctl restart myclaude"
    echo "  4. Test with: myclaude"
    echo
    echo -e "${CYAN}Useful commands:${NC}"
    echo "  myclaude                    # Launch Claude Code via proxy"
    echo "  sudo systemctl status myclaude  # Check service status"
    echo "  sudo journalctl -u myclaude -f  # View logs"
    echo "  sudo $INSTALL_DIR/uninstall.sh  # Uninstall"
    echo
}

main() {
    parse_args "$@"
    check_root
    check_existing_installation
    install_dependencies
    create_directories
    discover_ports
    install_python_deps
    generate_env_file
    build_config
    install_systemd_service
    install_nginx_config
    install_logrotate
    setup_https
    install_launcher
    set_permissions
    start_services
    verify_installation
    print_summary
}

main "$@"