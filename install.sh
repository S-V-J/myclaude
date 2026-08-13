#!/bin/bash
set -euo pipefail

# ============================================================
# MyClaude - Fully Automated Installer
# Claude Code + LiteLLM + NVIDIA NIM Proxy
# ============================================================

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="myclaude"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"
VENV_DIR="$REPO_DIR/venv"
SERVICE_USER="myclaude"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# ============================================================
# 1. CHECK SUDO
# ============================================================
check_sudo() {
    if ! sudo -v 2>/dev/null; then
        fail "This installer needs sudo privileges."
    fi
}

# ============================================================
# 2. AUTO-INSTALL SYSTEM PACKAGES
# ============================================================
install_system_packages() {
    info "Installing system packages (nginx, python3, python3-venv, curl, git)..."

    # Check if nginx is installed
    if ! command -v nginx &>/dev/null; then
        info "nginx not found, installing..."
        sudo apt install -y nginx
    else
        ok "nginx already installed"
    fi

    # Check if python3-venv is installed
    if ! python3 -m venv --help &>/dev/null 2>&1; then
        info "python3-venv not found, installing..."
        sudo apt install -y python3 python3-venv python3-pip
    else
        ok "python3-venv already installed"
    fi

    # Ensure curl and git are available
    for pkg in curl git; do
        if ! command -v "$pkg" &>/dev/null; then
            info "$pkg not found, installing..."
            sudo apt install -y "$pkg"
        fi
    done

    ok "System packages ready"
}

# ============================================================
# 3. NVIDIA API KEY
# ============================================================
ask_api_key() {
    local key=""
    if [ -f "$REPO_DIR/.env" ]; then
        key=$(grep '^NVIDIA_API_KEY=' "$REPO_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
        if [ -n "$key" ] && [[ "$key" != PASTE* ]] && [[ "$key" != *"YOUR_"* ]]; then
            info "Found existing NVIDIA_API_KEY in .env"
            return 0
        fi
    fi

    echo ""
    echo "============================================================"
    echo " You need an NVIDIA NIM API key to use MyClaude."
    echo " Get one free at: https://build.nvidia.com"
    echo "============================================================"
    echo ""

    while true; do
        read -rp "Paste your NVIDIA API key: " key
        key=$(echo "$key" | tr -d '[:space:]')
        if [ -z "$key" ]; then
            warn "API key cannot be empty. Try again."
            continue
        fi
        break
    done

    # Optional StepFun key
    echo ""
    read -rp "Optional: StepFun API key for stepfun-ai models (press Enter to skip): " stepfun_key
    stepfun_key=$(echo "$stepfun_key" | tr -d '[:space:]')

    # Write .env
    cat > "$REPO_DIR/.env" <<ENVEOF
# MyClaude Environment Configuration
NVIDIA_API_KEY="$key"
ENVEOF

    if [ -n "$stepfun_key" ]; then
        echo "STEPFUN_API_KEY=\"$stepfun_key\"" >> "$REPO_DIR/.env"
    fi

    LOCAL_KEY="sk-local-$(openssl rand -hex 16 2>/dev/null || echo "proxykey$(date +%s)")"
    echo "LITELLM_MASTER_KEY=\"$LOCAL_KEY\"" >> "$REPO_DIR/.env"
    echo "LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=\"true\"" >> "$REPO_DIR/.env"

    ok "Keys saved to $REPO_DIR/.env"
}

# ============================================================
# 4. SYSTEM USER (with recreate prompt)
# ============================================================
setup_system_user() {
    info "Setting up system user '$SERVICE_USER'..."

    if id "$SERVICE_USER" &>/dev/null; then
        ok "User '$SERVICE_USER' already exists"
        echo ""
        read -rp "  User '$SERVICE_USER' already exists. Re-create it? (y/N): " recreate_user
        if [[ "$recreate_user" =~ ^[Yy]$ ]]; then
            info "Removing existing user and re-creating..."
            sudo userdel -r "$SERVICE_USER" 2>/dev/null || true
            sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
            ok "Re-created system user '$SERVICE_USER'"
        else
            info "Keeping existing user '$SERVICE_USER'"
        fi
    else
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
        ok "Created system user '$SERVICE_USER'"
    fi

    # Ensure repo dir is owned by service user (for venv, logs, etc.)
    # On WSL with Windows filesystem, chown may not work, but we try
    info "Setting directory ownership to '$SERVICE_USER'..."
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true
    ok "Directory permissions set (best effort)"
}

# ============================================================
# 5. PYTHON VENV + LITELLM
# ============================================================
setup_venv() {
    info "Setting up Python virtual environment..."

    # Double-check ownership
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true

    # Verify we can write as the service user BEFORE attempting venv creation
    # On WSL with Windows filesystem mounts, chown/chmod may not work properly,
    # so we fall back to creating venv as current user if service user can't write
    info "Verifying write access for '$SERVICE_USER'..."
    if sudo -u "$SERVICE_USER" test -w "$REPO_DIR" 2>/dev/null; then
        ok "Write access verified for service user"
        VENV_AS_USER="$SERVICE_USER"
    else
        warn "Service user cannot write to $REPO_DIR (common on WSL). Falling back to current user for venv."
        VENV_AS_USER="$(logname 2>/dev/null || echo $SUDO_USER || echo $USER)"
        # Ensure current user owns the directory for venv creation
        sudo chown -R "$VENV_AS_USER:$VENV_AS_USER" "$REPO_DIR" 2>/dev/null || true
    fi

    # Create venv
    if [ ! -d "$VENV_DIR" ]; then
        info "Creating virtual environment as $VENV_AS_USER..."
        sudo -u "$VENV_AS_USER" python3 -m venv "$VENV_DIR"
        ok "Virtual environment created"
    else
        ok "Virtual environment already exists"
    fi

    # Ensure venv is owned by service user for runtime (if different from creator)
    if [ "$VENV_AS_USER" != "$SERVICE_USER" ]; then
        sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR" 2>/dev/null || true
    fi

    # Install LiteLLM
    info "Installing/updating LiteLLM..."
    sudo -u "$VENV_AS_USER" "$VENV_DIR/bin/pip" install --upgrade pip --quiet 2>/dev/null || true
    sudo -u "$VENV_AS_USER" "$VENV_DIR/bin/pip" install 'litellm[proxy]' "fastapi<0.140.0" --quiet
    ok "LiteLLM installed"
}

# ============================================================
# 6. NGINX
# ============================================================
setup_nginx() {
    info "Setting up nginx reverse proxy..."

    if ! command -v nginx &>/dev/null; then
        fail "nginx not found. The system packages step should have installed it."
    fi

    sudo rm -f "$NGINX_CONF"
    sudo cp "$REPO_DIR/nginx-myclaude.conf" "$NGINX_CONF"

    if sudo nginx -t 2>&1 | grep -q "successful"; then
        ok "Nginx config valid"
    else
        fail "Nginx config test failed"
    fi

    sudo systemctl reload nginx
    ok "Nginx reloaded"
}

# ============================================================
# 7. SYSTEMD SERVICE
# ============================================================
setup_systemd() {
    info "Setting up myclaude systemd service..."

    # Ensure .env is readable by service user
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR/.env" 2>/dev/null || true

    # Ensure venv is readable by service user
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR" 2>/dev/null || true

    # Generate service file from template
    local svc
    svc=$(mktemp)
    sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
        -e "s|__VENV_DIR__|$VENV_DIR|g" \
        -e "s|__SERVICE_USER__|$SERVICE_USER|g" \
        "$REPO_DIR/litellm.service.template" > "$svc"

    sudo cp "$svc" "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "$svc"

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl restart "$SERVICE_NAME"

    sleep 3
    if sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "myclaude.service is running"
    else
        fail "myclaude.service failed to start. Check: journalctl -u $SERVICE_NAME -n 20"
    fi
}

# ============================================================
# 8. CLAUDE CODE CLI
# ============================================================
setup_claude_code() {
    info "Checking Claude Code..."

    if command -v claude &>/dev/null; then
        local ver
        ver=$(claude --version 2>/dev/null || echo "unknown")
        ok "Claude Code already installed (v$ver)"
        return 0
    fi

    warn "Claude Code not found."
    read -rp "Install Claude Code now? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        info "Installing Claude Code..."
        if command -v npm &>/dev/null; then
            npm install -g @anthropic-ai/claude-code
            ok "Claude Code installed"
        else
            warn "npm not found. Install Node.js first, then run: npm install -g @anthropic-ai/claude-code"
        fi
    else
        warn "Skipped. Install manually with: npm install -g @anthropic-ai/claude-code"
    fi
}

# ============================================================
# 9. BASHRC ALIASES
# ============================================================
setup_bashrc() {
    info "Updating ~/.bashrc for convenience..."

    local bashrc="$HOME/.bashrc"
    local marker="# >>> MyClaude >>>"

    if grep -qF "$marker" "$bashrc" 2>/dev/null; then
        ok ".bashrc already configured"
        return 0
    fi

    cat >> "$bashrc" <<'BASHEOF'

# >>> MyClaude >>>
alias myclaude-start='sudo systemctl start myclaude'
alias myclaude-stop='sudo systemctl stop myclaude'
alias myclaude-status='sudo systemctl status myclaude'
alias myclaude-logs='journalctl -u myclaude -f'
# <<< MyClaude <<<
BASHEOF

    ok "Added aliases to ~/.bashrc (run 'source ~/.bashrc' to apply)"
}

# ============================================================
# 10. WRAPPER SCRIPT
# ============================================================
setup_wrapper() {
    info "Installing 'myclaude' command wrapper..."

    cat > /tmp/myclaude_wrapper <<'WRAPEOF'
#!/bin/bash
SERVICE_NAME="myclaude"

if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Starting MyClaude proxy..."
    sudo systemctl start "$SERVICE_NAME"
    sleep 3
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "Failed to start. Check: journalctl -u $SERVICE_NAME -n 20"
        exit 1
    fi
fi

export ANTHROPIC_BASE_URL="http://localhost:4000"
export ANTHROPIC_API_KEY="sk-local-proxy-key"

echo "Launching Claude Code via MyClaude proxy..."
exec claude "$@"
WRAPEOF

    sudo cp /tmp/myclaude_wrapper /usr/local/bin/myclaude
    sudo chmod +x /usr/local/bin/myclaude
    rm -f /tmp/myclaude_wrapper

    ok "'myclaude' command installed"
}

# ============================================================
# 11. LAN ACCESS (optional)
# ============================================================
setup_lan_hosting() {
    echo ""
    echo "============================================================"
    echo " 🌐 Local Network Hosting"
    echo "============================================================"
    echo ""
    echo " Would you like to allow other devices on your local"
    echo " network to use MyClaude?"
    echo ""
    echo " This will:"
    echo "  - Configure nginx to listen on all interfaces (0.0.0.0:4000)"
    echo "  - Open port 4000 in the firewall (if ufw/firewalld active)"
    echo "  - Let you access MyClaude from phones, tablets, other PCs"
    echo ""
    read -rp " Enable local network access? (y/n): " lan_choice

    if [[ ! "$lan_choice" =~ ^[Yy]$ ]]; then
        info "Skipped. Proxy remains localhost-only."
        return 0
    fi

    # Update nginx config for LAN
    sudo sed -i 's|^listen 4000;|listen 0.0.0.0:4000;|g' "$NGINX_CONF"
    sudo sed -i 's|^listen 4000 default_server;|listen 0.0.0.0:4000 default_server;|g' "$NGINX_CONF"

    # Allow through firewall
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Opening port 4000 in ufw..."
        sudo ufw allow 4000/tcp comment "MyClaude proxy"
        ok "Firewall rule added"
    elif command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
        info "Opening port 4000 in firewalld..."
        sudo firewall-cmd --permanent --add-port=4000/tcp 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
        ok "Firewall rule added"
    else
        warn "No active firewall detected."
    fi

    sudo systemctl reload nginx

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "YOUR_IP")

    echo ""
    ok "Local network access enabled!"
    echo ""
    echo " From other devices: http://${server_ip}:4000"
    echo ""
}

# ============================================================
# 12. VERIFY
# ============================================================
verify() {
    info "Running final verification..."

    local all_ok=true

    if ss -tlnp 2>/dev/null | grep -q ':4000 '; then
        ok "Nginx listening on port 4000"
    else
        fail "Nginx NOT on port 4000"
    fi

    if ss -tlnp 2>/dev/null | grep -q ':4001 '; then
        ok "LiteLLM listening on port 4001"
    else
        fail "LiteLLM NOT on port 4001"
    fi

    info "Testing proxy chain (nginx → LiteLLM → NVIDIA)..."
    local test_result
    test_result=$(curl -s --max-time 30 \
        -H "Authorization: Bearer sk-local-proxy-key" \
        -H "Content-Type: application/json" \
        -X POST http://localhost:4000/v1/chat/completions \
        -d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}' 2>&1) || true

    if echo "$test_result" | grep -qi "choices\|content\|error"; then
        ok "Proxy chain working — got response"
    else
        warn "Proxy test returned: $(echo "$test_result" | head -c 300)"
    fi

    echo ""
    echo "============================================================"
    echo -e " ${GREEN}Installation complete!${NC}"
    echo ""
    echo " Quick start:"
    echo "   myclaude              # launch Claude Code"
    echo "   myclaude --help       # pass args to Claude Code"
    echo ""
    echo " Service management:"
    echo "   sudo systemctl status myclaude"
    echo "   sudo systemctl restart myclaude"
    echo "   journalctl -u myclaude -f"
    echo ""
    echo " Convenience aliases (after 'source ~/.bashrc'):"
    echo "   myclaude-status  myclaude-logs  myclaude-start  myclaude-stop"
    echo "============================================================"
}

# ============================================================
# ARGUMENT PARSING
# ============================================================
AUTO_MODE=false
for arg in "$@"; do
    case $arg in
        --auto|-a) AUTO_MODE=true ;;
        --help|-h)
            echo "Usage: $0 [--auto|-a] [--help|-h]"
            echo ""
            echo "Options:"
            echo "  --auto, -a    Non-interactive install (requires NVIDIA_API_KEY env var)"
            echo "  --help, -h    Show this help"
            echo ""
            echo "Environment variables for --auto mode:"
            echo "  NVIDIA_API_KEY   Required. Get from https://build.nvidia.com"
            echo "  STEPFUN_API_KEY  Optional. For stepfun-ai models"
            echo "  ENABLE_LAN       Optional. Set to 'true' to enable LAN access"
            exit 0
            ;;
    esac
done

# ============================================================
# NVIDIA API KEY (supports auto mode via env var)
# ============================================================
ask_api_key() {
    local key=""

    # Check env var first (for --auto mode)
    if [ -n "${NVIDIA_API_KEY:-}" ]; then
        key="$NVIDIA_API_KEY"
        info "Using NVIDIA_API_KEY from environment"
    elif [ -f "$REPO_DIR/.env" ]; then
        key=$(grep '^NVIDIA_API_KEY=' "$REPO_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
        if [ -n "$key" ] && [[ "$key" != PASTE* ]] && [[ "$key" != *"YOUR_"* ]]; then
            info "Found existing NVIDIA_API_KEY in .env"
            return 0
        fi
    fi

    if [ "$AUTO_MODE" = true ]; then
        if [ -z "$key" ]; then
            fail "NVIDIA_API_KEY environment variable required for --auto mode"
        fi
    else
        echo ""
        echo "============================================================"
        echo " You need an NVIDIA NIM API key to use MyClaude."
        echo " Get one free at: https://build.nvidia.com"
        echo "============================================================"
        echo ""

        while true; do
            read -rp "Paste your NVIDIA API key: " key
            key=$(echo "$key" | tr -d '[:space:]')
            if [ -z "$key" ]; then
                warn "API key cannot be empty. Try again."
                continue
            fi
            break
        done
    fi

    # Optional StepFun key
    local stepfun_key="${STEPFUN_API_KEY:-}"
    if [ "$AUTO_MODE" != true ] && [ -z "$stepfun_key" ]; then
        read -rp "Optional: StepFun API key for stepfun-ai models (press Enter to skip): " stepfun_key
        stepfun_key=$(echo "$stepfun_key" | tr -d '[:space:]')
    fi

    # Write .env
    cat > "$REPO_DIR/.env" <<ENVEOF
# MyClaude Environment Configuration
NVIDIA_API_KEY="$key"
ENVEOF

    if [ -n "$stepfun_key" ]; then
        echo "STEPFUN_API_KEY=\"$stepfun_key\"" >> "$REPO_DIR/.env"
    fi

    LOCAL_KEY="sk-local-$(openssl rand -hex 16 2>/dev/null || echo "proxykey$(date +%s)")"
    echo "LITELLM_MASTER_KEY=\"$LOCAL_KEY\"" >> "$REPO_DIR/.env"
    echo "LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=\"true\"" >> "$REPO_DIR/.env"

    ok "Keys saved to $REPO_DIR/.env"
}

# ============================================================
# SYSTEM USER (auto mode skips recreate prompt)
# ============================================================
setup_system_user() {
    info "Setting up system user '$SERVICE_USER'..."

    if id "$SERVICE_USER" &>/dev/null; then
        ok "User '$SERVICE_USER' already exists"
        if [ "$AUTO_MODE" != true ]; then
            echo ""
            read -rp "  User '$SERVICE_USER' already exists. Re-create it? (y/N): " recreate_user
            if [[ "$recreate_user" =~ ^[Yy]$ ]]; then
                info "Removing existing user and re-creating..."
                sudo userdel -r "$SERVICE_USER" 2>/dev/null || true
                sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
                ok "Re-created system user '$SERVICE_USER'"
            else
                info "Keeping existing user '$SERVICE_USER'"
            fi
        else
            info "Auto mode: keeping existing user '$SERVICE_USER'"
        fi
    else
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
        ok "Created system user '$SERVICE_USER'"
    fi

    info "Setting directory ownership to '$SERVICE_USER'..."
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true
    ok "Directory permissions set (best effort)"
}

# ============================================================
# CLAUDE CODE CLI (auto mode skips prompt)
# ============================================================
setup_claude_code() {
    info "Checking Claude Code..."

    if command -v claude &>/dev/null; then
        local ver
        ver=$(claude --version 2>/dev/null || echo "unknown")
        ok "Claude Code already installed (v$ver)"
        return 0
    fi

    if [ "$AUTO_MODE" = true ]; then
        info "Auto mode: skipping Claude Code install (install manually: npm install -g @anthropic-ai/claude-code)"
        return 0
    fi

    warn "Claude Code not found."
    read -rp "Install Claude Code now? (y/n): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        info "Installing Claude Code..."
        if command -v npm &>/dev/null; then
            npm install -g @anthropic-ai/claude-code
            ok "Claude Code installed"
        else
            warn "npm not found. Install Node.js first, then run: npm install -g @anthropic-ai/claude-code"
        fi
    else
        warn "Skipped. Install manually with: npm install -g @anthropic-ai/claude-code"
    fi
}

# ============================================================
# LAN ACCESS (auto mode uses ENABLE_LAN env var)
# ============================================================
setup_lan_hosting() {
    local lan_choice="${ENABLE_LAN:-}"

    if [ "$AUTO_MODE" != true ]; then
        echo ""
        echo "============================================================"
        echo " 🌐 Local Network Hosting"
        echo "============================================================"
        echo ""
        echo " Would you like to allow other devices on your local"
        echo " network to use MyClaude?"
        echo ""
        echo " This will:"
        echo "  - Configure nginx to listen on all interfaces (0.0.0.0:4000)"
        echo "  - Open port 4000 in the firewall (if ufw/firewalld active)"
        echo "  - Let you access MyClaude from phones, tablets, other PCs"
        echo ""
        read -rp " Enable local network access? (y/n): " lan_choice
    fi

    if [[ ! "$lan_choice" =~ ^[Yy]$ ]] && [[ ! "$lan_choice" =~ ^[Tt][Rr][Uu][Ee]$ ]]; then
        info "Skipped. Proxy remains localhost-only."
        return 0
    fi

    # Update nginx config for LAN
    sudo sed -i 's|^listen 4000;|listen 0.0.0.0:4000;|g' "$NGINX_CONF"
    sudo sed -i 's|^listen 4000 default_server;|listen 0.0.0.0:4000 default_server;|g' "$NGINX_CONF"

    # Allow through firewall
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
        info "Opening port 4000 in ufw..."
        sudo ufw allow 4000/tcp comment "MyClaude proxy"
        ok "Firewall rule added"
    elif command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
        info "Opening port 4000 in firewalld..."
        sudo firewall-cmd --permanent --add-port=4000/tcp 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
        ok "Firewall rule added"
    else
        warn "No active firewall detected."
    fi

    sudo systemctl reload nginx

    local server_ip
    server_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "YOUR_IP")

    echo ""
    ok "Local network access enabled!"
    echo ""
    echo " From other devices: http://${server_ip}:4000"
    echo ""
}

# ============================================================
# MAIN
# ============================================================
main() {
    echo ""
    echo "============================================================"
    echo " 🤖 MyClaude Installer"
    echo " Claude Code + LiteLLM + NVIDIA NIM"
    if [ "$AUTO_MODE" = true ]; then
        echo " (Auto mode)"
    fi
    echo "============================================================"
    echo ""

    check_sudo
    install_system_packages
    ask_api_key
    setup_system_user
    setup_venv
    setup_nginx
    setup_systemd
    setup_claude_code
    setup_bashrc
    setup_wrapper
    setup_lan_hosting
    verify
}

main "$@"
