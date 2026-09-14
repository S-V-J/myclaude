#!/bin/bash
# MyClaude Uninstallation Script
# Safely removes all MyClaude components

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Defaults
INSTALL_DIR="${MYCLAUDE_INSTALL_DIR:-$HOME/myclaude}"
SERVICE_NAME="myclaude"
SKIP_BACKUP="${SKIP_BACKUP:-false}"

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

MyClaude Uninstallation System

Options:
  --dir DIR              Installation directory (default: \$HOME/myclaude)
  --skip-backup          Skip creating backup before uninstall
  --help                 Show this help

Environment Variables:
  MYCLAUDE_INSTALL_DIR   Installation directory
  SKIP_BACKUP            Skip backup (true/false)

Examples:
  $0                                      # Standard uninstall with backup
  $0 --skip-backup                        # Uninstall without backup
EOF
    exit 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dir) INSTALL_DIR="$2"; shift 2 ;;
            --skip-backup) SKIP_BACKUP="true"; shift ;;
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

create_backup() {
    if [[ "$SKIP_BACKUP" == "true" ]]; then
        log_warn "Skipping backup as requested"
        return 0
    fi

    log_info "Creating backup of MyClaude installation..."
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="/tmp/myclaude-backup-${timestamp}"

    mkdir -p "$backup_dir"

    # Backup config files
    if [[ -d "$INSTALL_DIR" ]]; then
        cp -r "$INSTALL_DIR" "$backup_dir/" 2>/dev/null || true
        log_info "Backed up installation directory to $backup_dir"
    fi

    # Backup systemd service
    if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
        cp "/etc/systemd/system/${SERVICE_NAME}.service" "$backup_dir/"
    fi

    # Backup nginx config
    if [[ -f "/etc/nginx/sites-enabled/myclaude" ]]; then
        cp "/etc/nginx/sites-enabled/myclaude" "$backup_dir/"
    fi
    if [[ -f "/etc/nginx/sites-available/myclaude" ]]; then
        cp "/etc/nginx/sites-available/myclaude" "$backup_dir/"
    fi

    # Backup logrotate config
    if [[ -f "/etc/logrotate.d/myclaude" ]]; then
        cp "/etc/logrotate.d/myclaude" "$backup_dir/"
    fi

    # Backup launcher
    if [[ -f "/usr/local/bin/myclaude" ]]; then
        cp "/usr/local/bin/myclaude" "$backup_dir/"
    fi

    log_success "Backup created at $backup_dir"
}

stop_services() {
    log_info "Stopping MyClaude services..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true

    # Stop nginx only if no other sites depend on it
    if [[ "$(find /etc/nginx/sites-enabled/ -type l | wc -l)" -eq 1 ]]; then
        log_info "Stopping nginx (no other sites enabled)"
        systemctl stop nginx 2>/dev/null || true
        systemctl disable nginx 2>/dev/null || true
    else
        log_info "Reloading nginx (other sites present)"
        nginx -s reload 2>/dev/null || true
    fi

    log_success "Services stopped"
}

remove_systemd_service() {
    log_info "Removing systemd service..."
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    log_success "Systemd service removed"
}

remove_nginx_config() {
    log_info "Removing Nginx configuration..."
    rm -f "/etc/nginx/sites-enabled/myclaude"
    rm -f "/etc/nginx/sites-available/myclaude"

    # Remove rate limit zone if it's our only one (basic check)
    # Note: This is conservative - we don't remove if others might use it
    log_info "Nginx configuration removed (rate limit zone preserved for safety)"
    nginx -t && nginx -s reload 2>/dev/null || true
    log_success "Nginx configuration removed"
}

remove_logrotate() {
    log_info "Removing logrotate configuration..."
    rm -f "/etc/logrotate.d/myclaude"
    log_success "Logrotate configuration removed"
}

remove_launcher() {
    log_info "Removing launcher..."
    rm -f "/usr/local/bin/myclaude"
    log_success "Launcher removed"
}

remove_installation_dir() {
    if [[ -d "$INSTALL_DIR" ]]; then
        log_info "Removing installation directory: $INSTALL_DIR"
        read -rp "Are you sure you want to delete $INSTALL_DIR? (y/N) " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
            log_success "Installation directory removed"
        else
            log_warn "Installation directory preserved"
        fi
    else
        log_warn "Installation directory not found: $INSTALL_DIR"
    fi
}

cleanup_tmp() {
    log_info "Cleaning up temporary files..."
    rm -f /tmp/myclaude*.lock
    rm -rf /tmp/myclaude
    log_success "Temporary files cleaned"
}

print_summary() {
    echo
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}        MyClaude Uninstallation Complete${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo
    echo -e "${YELLOW}Manual cleanup may be needed for:${NC}"
    echo "  - SSL/TLS certificates (check /etc/letsencrypt/live/)"
    echo "  - Custom nginx configuration additions"
    echo "  - System user '${SERVICE_USER}' (if created for MyClaude)"
    echo
    echo -e "${CYAN}To completely remove MyClaude user:${NC}"
    echo "  sudo deluser --remove-home $SERVICE_USER"
    echo
}

main() {
    parse_args "$@"
    check_root

    log_info "Starting MyClaude uninstallation..."
    log_info "Installation directory: $INSTALL_DIR"

    stop_services
    remove_systemd_service
    remove_nginx_config
    remove_logrotate
    remove_launcher
    cleanup_tmp
    remove_installation_dir
    print_summary
}

main "$@"