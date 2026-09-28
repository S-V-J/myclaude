#!/bin/bash
# MyClaude TLS Setup Script
# Sets up HTTPS using Let's Encrypt for MyClaude proxy
# Uses dynamic port discovery from .env

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
REPO_DIR="${MYCLAUDE_INSTALL_DIR:-$HOME/myclaude}"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

MyClaude TLS Setup

Options:
  --domain DOMAIN      TLS domain name (required)
  --repo-dir DIR       MyClaude installation directory (default: \$HOME/myclaude)
  --help               Show this help

Environment Variables:
  MYCLAUDE_INSTALL_DIR MyClaude installation directory
  MYCLAUDE_TLS_DOMAIN  TLS domain name

Note: Ports are read from .env file (dynamic ports)

Examples:
  $0 --domain api.example.com
EOF
    exit 1
}

parse_args() {
    TLS_DOMAIN="${MYCLAUDE_TLS_DOMAIN:-}"
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain) TLS_DOMAIN="$2"; shift 2 ;;
            --repo-dir) REPO_DIR="$2"; shift 2 ;;
            --help) usage ;;
            *) log_error "Unknown option: $1"; usage ;;
        esac
    done
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Detect Linux distribution
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID,,}"
        return 0
    else
        log_error "Cannot detect Linux distribution (missing /etc/os-release)"
        exit 1
    fi
}

check_dependencies() {
    log_info "Checking dependencies..."

    detect_distro

    # Define package names per distribution for certbot
    case "$DISTRO_ID" in
        ubuntu|debian|linuxmint|pop|elementary|kali|parrot)
            CERTBOT_DEPS=(certbot python3-certbot-nginx)
            PKG_MANAGER="apt-get"
            PKG_UPDATE="apt-get update -qq >/dev/null 2>&1"
            PKG_INSTALL="DEBIAN_FRONTEND=noninteractive apt-get install -y"
            PKG_CHECK="dpkg -l | grep -q \"^ii\""
            ;;
        fedora|centos|rhel|rocky|almalinux|oracle)
            CERTBOT_DEPS=(certbot python3-certbot-nginx)
            PKG_MANAGER="dnf"
            PKG_UPDATE="dnf makecache -q >/dev/null 2>&1"
            PKG_INSTALL="dnf install -y"
            PKG_CHECK="dnf list installed"
            ;;
        arch|manjaro|endeavouros|garuda)
            CERTBOT_DEPS=(certbot certbot-nginx)
            PKG_MANAGER="pacman"
            PKG_UPDATE="pacman -Sy --noconfirm >/dev/null 2>&1"
            PKG_INSTALL="pacman -S --noconfirm"
            PKG_CHECK="pacman -Q"
            ;;
        opensuse*|suse|sles)
            CERTBOT_DEPS=(certbot python3-certbot-nginx)
            PKG_MANAGER="zypper"
            PKG_UPDATE="zypper refresh -q >/dev/null 2>&1"
            PKG_INSTALL="zypper install -y"
            PKG_CHECK="zypper search -i"
            ;;
        alpine)
            CERTBOT_DEPS=(certbot certbot-nginx)
            PKG_MANAGER="apk"
            PKG_UPDATE="apk update >/dev/null 2>&1"
            PKG_INSTALL="apk add --no-cache"
            PKG_CHECK="apk info -e"
            ;;
        *)
            log_error "Unsupported Linux distribution: $DISTRO_ID"
            exit 1
            ;;
    esac

    log_info "Detected distribution: $DISTRO_ID (using $PKG_MANAGER)"

    # Check if certbot dependencies are installed
    local missing=()
    for dep in "${CERTBOT_DEPS[@]}"; do
        if ! eval "$PKG_CHECK $dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_info "Installing missing certbot dependencies: ${missing[*]}"
        eval "$PKG_UPDATE"
        eval "$PKG_INSTALL ${missing[*]}" >/dev/null 2>&1
        log_success "Certbot dependencies installed"
    fi

    # Check nginx and certbot commands
    local missing_cmds=()
    for cmd in certbot nginx; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [[ ${#missing_cmds[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_cmds[*]}"
        exit 1
    fi

    log_success "All dependencies found"
}

find_free_port() {
    local start_port="${1:-8443}"
    local port="$start_port"

    for ((port=start_port; port<=50000; port++)); do
        if ! ss -tuln | grep -q ":${port} "; then
            echo "$port"
            return 0
        fi
    done

    log_error "Could not find free port in range $start_port-50000"
    return 1
}

read_ports_from_env() {
    if [[ ! -f "$REPO_DIR/.env" ]]; then
        log_error ".env file not found at $REPO_DIR/.env"
        exit 1
    fi

    HTTPS_PORT=$(grep -E '^HTTPS_PORT=' "$REPO_DIR/.env" | cut -d= -f2 | sed "s/^[\"']//; s/[\"']$//")
    NGINX_PORT=$(grep -E '^NGINX_PORT=' "$REPO_DIR/.env" | cut -d= -f2 | sed "s/^[\"']//; s/[\"']$//")
    LITELLM_PORT=$(grep -E '^LITELLM_PORT=' "$REPO_DIR/.env" | cut -d= -f2 | sed "s/^[\"']//; s/[\"']$//")

    # If HTTPS_PORT not set or is 0/empty, find a free one
    if [[ -z "$HTTPS_PORT" || "$HTTPS_PORT" -eq 0 ]]; then
        log_info "HTTPS_PORT not set in .env, finding free port..."
        HTTPS_PORT=$(find_free_port $((NGINX_PORT + 100)))
        # Update .env
        sed -i "s|^HTTPS_PORT=.*|HTTPS_PORT=${HTTPS_PORT}|" "$REPO_DIR/.env"
        log_info "Assigned HTTPS_PORT=$HTTPS_PORT"
    fi
}

validate_config() {
    if [[ -z "$TLS_DOMAIN" ]]; then
        log_error "--domain is required"
        exit 1
    fi

    if [[ ! -f "$REPO_DIR/nginx-myclaude.conf" ]]; then
        log_error "MyClaude nginx config not found at $REPO_DIR/nginx-myclaude.conf"
        exit 1
    fi

    if [[ ! -f "$NGINX_CONF" ]]; then
        log_error "MyClaude nginx site not enabled. Run install.sh first or enable manually:"
        exit 1
    fi
}

setup_tls() {
    log_info "Setting up TLS certificate for $TLS_DOMAIN..."

    # Backup current nginx config
    cp "$NGINX_CONF" "${NGINX_CONF}.backup.$(date +%Y%m%d_%H%M%S)"

    # Update nginx config with HTTPS port and domain
    sed -i "s|__NGINX_HTTPS_PORT__|${HTTPS_PORT}|g" "$REPO_DIR/nginx-myclaude.conf"
    sed -i "s|__TLS_DOMAIN__|${TLS_DOMAIN}|g" "$REPO_DIR/nginx-myclaude.conf"

    # Copy updated config to enabled site
    cp "$REPO_DIR/nginx-myclaude.conf" "$NGINX_CONF"

    # Test nginx config
    if ! nginx -t; then
        log_error "Nginx configuration test failed"
        mv "${NGINX_CONF}.backup.$(date +%Y%m%d_%H%M%S)" "$NGINX_CONF"
        exit 1
    fi

    # Obtain certificate
    log_info "Obtaining Let's Encrypt certificate..."
    certbot --nginx -d "$TLS_DOMAIN" --non-interactive --agree-tos --redirect \
        --email "admin@$TLS_DOMAIN" || {
        log_error "Failed to obtain TLS certificate"
        exit 1
    }

    # Reload nginx
    nginx -t && systemctl reload nginx

    log_success "TLS certificate obtained and configured for $TLS_DOMAIN"
    log_info "HTTPS is now available on port ${HTTPS_PORT}"
}

print_summary() {
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}        MyClaude TLS Setup Complete${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "Domain:           ${GREEN}$TLS_DOMAIN${NC}"
    echo -e "HTTPS Port:       ${GREEN}$HTTPS_PORT${NC}"
    echo -e "Nginx Config:     ${GREEN}$NGINX_CONF${NC}"
    echo
    echo -e "${CYAN}Next steps:${NC}"
    echo "  1. Test HTTPS: curl -k https://${TLS_DOMAIN}:${HTTPS_PORT}/health"
    echo "  2. Restart MyClaude: sudo systemctl restart myclaude"
    echo
}

main() {
    parse_args "$@"
    check_root
    check_dependencies
    read_ports_from_env
    validate_config
    setup_tls
    print_summary
}

main "$@"