#!/bin/bash
# Module: 01-detect-os
# Detect OS and package manager

run_01_detect_os() {
    detect_os
}

# Detect OS and package manager
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-}"
        OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
    else
        OS_ID="unknown"
        OS_VERSION=""
        OS_PRETTY="Unknown Linux"
    fi

    if command -v apt &>/dev/null; then
        PKG_MGR="apt"
        PKG_INSTALL="apt install -y"
        PKG_UPDATE="apt update -y"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
        PKG_INSTALL="dnf install -y"
        PKG_UPDATE="dnf check-update || true"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
        PKG_INSTALL="yum install -y"
        PKG_UPDATE="yum check-update || true"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
        PKG_INSTALL="pacman -Sy --noconfirm"
        PKG_UPDATE="pacman -Sy"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"
        PKG_INSTALL="zypper install -y"
        PKG_UPDATE="zypper refresh"
    else
        PKG_MGR="unknown"
        PKG_INSTALL="echo 'Cannot install packages automatically'"
        PKG_UPDATE="true"
    fi

    # Detect WSL
    if grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null; then
        IS_WSL=true
    else
        IS_WSL=false
    fi

    log_info "Detected: $OS_PRETTY (pkg: $PKG_MGR, WSL: $IS_WSL)"
}

# Check for TTY
has_tty() {
    [ -t 0 ] && [ -t 1 ]
}

# Export for other modules
export OS_ID OS_VERSION OS_PRETTY PKG_MGR PKG_INSTALL PKG_UPDATE IS_WSL