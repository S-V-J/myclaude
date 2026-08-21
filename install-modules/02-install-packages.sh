#!/bin/bash
# Module 02: Install system packages
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Installing system packages..."

case $PKG_MANAGER in
    apt)
        sudo apt update -y
        sudo apt install -y nginx python3 python3-venv python3-pip curl git openssl
        ;;
    dnf)
        sudo dnf install -y nginx python3 python3-virtualenv python3-pip curl git openssl
        ;;
    pacman)
        sudo pacman -Sy --noconfirm nginx python python-pip curl git openssl
        ;;
esac

# Verify installations
for cmd in nginx python3 pip3 curl git openssl; do
    if ! command -v $cmd &>/dev/null; then
        log_error "$cmd not found after installation"
        exit 1
    fi
done

log_info "System packages installed successfully"
