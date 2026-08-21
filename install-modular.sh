#!/bin/bash
# MyClaude One-Command Modular Installer
# Run with: bash <(curl -fsSL https://raw.githubusercontent.com/.../install-modular.sh)
# Or locally: bash install-modular.sh

set -euo pipefail

# Determine script directory
if [[ "${BASH_SOURCE[0]}" == /* ]]; then
    SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
else
    SCRIPT_DIR="$(pwd)"
fi

MODULES_DIR="$SCRIPT_DIR/install-modules"

# Source TUI helpers
source "$MODULES_DIR/tui-helpers.sh"

print_banner

log_info "Starting MyClaude modular installation..."
log_info "Install directory: $SCRIPT_DIR"
log_info "Running as user: $USER"

# Confirm before proceeding
if ! confirm "Install MyClaude proxy system?"; then
    log_info "Installation cancelled"
    exit 0
fi

# Run all modules in order
MODULES=(
    "01-detect-os.sh"
    "02-install-packages.sh"
    "03-setup-venv.sh"
    "04-write-env.sh"
    "05-setup-nginx.sh"
    "06-setup-systemd.sh"
    "07-setup-logrotate.sh"
    "08-setup-wrapper.sh"
    "09-setup-claude-code.sh"
    "10-setup-claude-settings.sh"
    "11-setup-bashrc.sh"
    "12-verify.sh"
)

for module in "${MODULES[@]}"; do
    print_step "Running $module..."
    if [[ -f "$MODULES_DIR/$module" ]]; then
        source "$MODULES_DIR/$module"
        log_success "$module completed"
    else
        log_error "Module not found: $module"
        exit 1
    fi
done

print_step "Starting services..."
sudo systemctl daemon-reload
sudo systemctl enable myclaude
sudo systemctl start myclaude
sudo systemctl restart nginx

print_step "Final verification..."
sleep 3

if systemctl is-active --quiet myclaude && systemctl is-active --quiet nginx; then
    log_success "MyClaude installation complete!"
    echo
    echo -e "${GREEN}Next steps:${NC}"
    echo "  1. Run 'source ~/.bashrc' or open a new terminal"
    echo "  2. Run 'myclaude' to start using Claude Code via the proxy"
    echo "  3. Check status with 'systemctl status myclaude'"
else
    log_error "Some services failed to start"
    systemctl status myclaude --no-pager
    systemctl status nginx --no-pager
    exit 1
fi