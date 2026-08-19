#!/bin/bash
# Module: 02-install-packages
# Install system packages

run_02_install_packages() {
    install_system_packages
}

install_system_packages() {
    log_info "Installing system packages via $PKG_MGR..."

    case "$PKG_MGR" in
        apt)
            sudo $PKG_UPDATE
            sudo $PKG_INSTALL nginx python3 python3-venv python3-pip curl git whiptail 2>/dev/null || true
            # Install whiptail for TUI if not present
            if ! command -v whiptail &>/dev/null; then
                sudo $PKG_INSTALL whiptail 2>/dev/null || true
            fi
            ;;
        dnf)
            sudo $PKG_INSTALL nginx python3 python3-venv python3-pip curl git newt 2>/dev/null || true
            ;;
        yum)
            sudo $PKG_INSTALL nginx python3 python3-venv python3-pip curl git newt 2>/dev/null || true
            ;;
        pacman)
            sudo $PKG_UPDATE
            sudo $PKG_INSTALL nginx python python-pip curl git libnewt 2>/dev/null || true
            ;;
        zypper)
            sudo $PKG_UPDATE
            sudo $PKG_INSTALL nginx python3 python3-venv python3-pip curl git python3-newt 2>/dev/null || true
            ;;
        *)
            log_warn "Unknown package manager. Please install manually: nginx python3 python3-venv python3-pip curl git"
            ;;
    esac

    # Ensure nginx is enabled
    sudo systemctl enable nginx 2>/dev/null || true

    log_success "System packages installed"
}