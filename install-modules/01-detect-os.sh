#!/bin/bash
# Module 01: Detect OS and set global variables
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Detect OS
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS=$ID
    OS_VERSION=$VERSION_ID
else
    log_error "Cannot detect OS"
    exit 1
fi

# Supported OS
case $OS in
    ubuntu|debian)
        PKG_MANAGER="apt"
        ;;
    fedora|rhel|centos|rocky|almalinux)
        PKG_MANAGER="dnf"
        ;;
    arch|manjaro)
        PKG_MANAGER="pacman"
        ;;
    *)
        log_warn "OS $OS not officially supported, trying apt..."
        PKG_MANAGER="apt"
        ;;
esac

# Current user (not root)
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_HOME=$(eval echo "~$INSTALL_USER")
REPO_DIR="$INSTALL_HOME/myclaude"

log_info "OS: $OS $OS_VERSION"
log_info "Package manager: $PKG_MANAGER"
log_info "Install user: $INSTALL_USER"
log_info "Repo dir: $REPO_DIR"

export OS OS_VERSION PKG_MANAGER INSTALL_USER INSTALL_HOME REPO_DIR
