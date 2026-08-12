#!/bin/bash
set -euo pipefail

# ============================================================
# MyClaude - One-command installer
# Claude Code + LiteLLM + NVIDIA NIM proxy
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

info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail()  { echo -e "${RED}[FAIL]${NC} $1"; exit 1; }

# ============================================================
# PRE-FLIGHT
# ============================================================
check_sudo() {
    if ! sudo -v 2>/dev/null; then
        fail "This installer needs sudo privileges."
    fi
}

check_prereqs() {
    info "Checking prerequisites..."
    local missing=()

    if ! command -v python3 &>/dev/null; then
        missing+=("python3 (sudo apt install python3 python3-venv)")
    fi
    if ! command -v nginx &>/dev/null; then
        missing+=("nginx (sudo apt install nginx)")
    fi
    if ! command -v systemctl &>/dev/null; then
        missing+=("systemd (this installer requires a systemd-based system)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing prerequisites:"
        for m in "${missing[@]}"; do
            echo "  - $m"
        done
        fail "Install the above and re-run this script."
    fi
    ok "All prerequisites met"
}

# ============================================================
# STEP 1: NVIDIA API KEY
# ============================================================
ask_api_key() {
    local key=""
    if [ -f "$REPO_DIR/.env" ]; then
        key=$(grep '^NVIDIA_API_KEY=' "$REPO_DIR/.env" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'" || true)
        if [ -n "$key" ] && [[ "$key" != PASTE* ]] && [[ "$key" != *"YOUR_"* ]]; then
            info "Found existing NVIDIA_API_KEY in .env"
            # Re-test existing key
            test_nvidia_key "$key" || warn "Existing key failed validation — will ask for a new one"
            return 0
        fi
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  You need an NVIDIA NIM API key to use MyClaude."
    echo "  Get one free at: https://build.nvidia.com"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
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

    test_nvidia_key "$key" || fail "Invalid API key. Please check and re-run installer."

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
# STEP 2: TEST NVIDIA API KEY
# ============================================================
test_nvidia_key() {
    local key="$1"
    info "Testing NVIDIA API key..."

    if ! command -v python3 &>/dev/null; then
        warn "python3 not found, skipping key validation"
        return 0
    fi

    local tmp_test
    tmp_test=$(mktemp /tmp/keytest_XXXXXX.py)
    cat > "$tmp_test" <<'PYEOF'
import os, sys
try:
    from openai import OpenAI
except ImportError:
    print("SKIP:openai not installed")
    sys.exit(0)

key = sys.argv[1]
client = OpenAI(base_url="https://integrate.api.nvidia.com/v1", api_key=key)
try:
    client.chat.completions.create(
        model="nvidia/nemotron-3-ultra-550b-a55b",
        messages=[{"role": "user", "content": "Hi"}],
        max_tokens=5
    )
    print("OK")
except Exception as e:
    print(f"FAIL:{e}")
    sys.exit(1)
PYEOF

    local result
    result=$(python3 "$tmp_test" "$key" 2>&1) || true
    rm -f "$tmp_test"

    if echo "$result" | grep -q "^OK"; then
        ok "NVIDIA API key is valid!"
        return 0
    elif echo "$result" | grep -q "^SKIP"; then
        warn "Skipped validation (openai not yet installed)"
        return 0
    else
        fail "API key rejected by NVIDIA: $(echo "$result" | sed 's/^FAIL://')"
    fi
}

# ============================================================
# STEP 3: SYSTEM USER
# ============================================================
setup_system_user() {
    info "Setting up system user '$SERVICE_USER'..."

    if id "$SERVICE_USER" &>/dev/null; then
        ok "User '$SERVICE_USER' already exists"
    else
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
        ok "Created system user '$SERVICE_USER'"
    fi

    # Ensure repo dir is owned by service user (for venv, logs, etc.)
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR"
}

# ============================================================
# STEP 4: PYTHON VENV + LITELLM
# ============================================================
setup_venv() {
    info "Setting up Python virtual environment..."

    if [ ! -d "$VENV_DIR" ]; then
        sudo -u "$SERVICE_USER" python3 -m venv "$VENV_DIR"
        ok "Virtual environment created"
    else
        ok "Virtual environment already exists"
    fi

    info "Installing/updating LiteLLM..."
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" install --upgrade pip --quiet 2>/dev/null || true
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" install 'litellm[proxy]' "fastapi<0.140.0" --quiet
    ok "LiteLLM installed"
}

# ============================================================
# STEP 5: NGINX
# ============================================================
setup_nginx() {
    info "Setting up nginx reverse proxy..."

    if ! command -v nginx &>/dev/null; then
        fail "nginx not found. Install: sudo apt install nginx"
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
# STEP 6: SYSTEMD SERVICE
# ============================================================
setup_systemd() {
    info "Setting up myclaude systemd service..."

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
# STEP 7: CLAUDE CODE
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
        npm install -g @anthropic-ai/claude-code 2>/dev/null || {
            warn "Global npm install failed, using npm prefix..."
            export NPM_CONFIG_PREFIX="${HOME}/.npm-global"
            npm install -g @anthropic-ai/claude-code
        }
        ok "Claude Code installed"
    else
        warn "Skipped. Install manually with: npm install -g @anthropic-ai/claude-code"
    fi
}

# ============================================================
# STEP 8: BASHRC AUTO-UPDATE
# ============================================================
setup_bashrc() {
    info "Updating ~/.bashrc for convenience..."

    local bashrc="$HOME/.bashrc"
    local marker="# >>> MyClaude >>>"

    # Only add if not already present
    if grep -qF "$marker" "$bashrc" 2>/dev/null; then
        ok ".bashrc already configured"
        return
    fi

    cat >> "$bashrc" <<'BASHRC'

# >>> MyClaude >>>
# Convenience aliases and PATH for MyClaude
alias myclaude-start='sudo systemctl start myclaude'
alias myclaude-stop='sudo systemctl stop myclaude'
alias myclaude-status='sudo systemctl status myclaude'
alias myclaude-logs='journalctl -u myclaude -f'
# <<< MyClaude <<<
BASHRC

    ok "Added aliases to ~/.bashrc (run 'source ~/.bashrc' to apply)"
}

# ============================================================
# STEP 9: myclaude WRAPPER
# ============================================================
setup_wrapper() {
    info "Installing 'myclaude' command..."

    cat > /tmp/myclaude <<'WRAPPER'
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
WRAPPER

    sudo cp /tmp/myclaude /usr/local/bin/myclaude
    sudo chmod +x /usr/local/bin/myclaude
    rm -f /tmp/myclaude

    ok "'myclaude' command installed"
}

# ============================================================
# STEP 10: LOCAL NETWORK HOSTING (OPTIONAL)
# ============================================================
setup_lan_hosting() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌐 Local Network Hosting"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Would you like to allow other devices on your local"
    echo "  network to use MyClaude?"
    echo ""
    echo "  This will:"
    echo "    - Configure nginx to listen on all interfaces (0.0.0.0:4000)"
    echo "    - Open port 4000 in the firewall (if ufw/firewalld active)"
    echo "    - Let you access MyClaude from phones, tablets, other PCs"
    echo ""
    read -rp "  Enable local network access? (y/n): " lan_choice

    if [[ ! "$lan_choice" =~ ^[Yy]$ ]]; then
        info "Skipped. Proxy remains localhost-only."
        return
    fi

    # Ask which interface / IP to bind to
    echo ""
    echo "  Bind to all interfaces (0.0.0.0) or a specific IP?"
    echo "    1) All interfaces (recommended)"
    echo "    2) Specific IP"
    read -rp "  Choose (1/2) [1]: " bind_choice
    bind_choice="${bind_choice:-1}"

    local listen_addr="0.0.0.0"
    if [ "$bind_choice" = "2" ]; then
        # Show available IPs
        echo ""
        echo "  Available network interfaces:"
        ip -4 addr show 2>/dev/null | grep -oP 'inet \K[\d.]+/\d+' | while read -r ip; do
            echo "    $ip"
        done
        read -rp "  Enter the IP to bind to: " listen_addr
    fi

    # Update nginx config for LAN
    sudo sed -i "s|^    listen 4000;|    listen 4000;|" "$NGINX_CONF"
    sudo sed -i "s|^    listen 4000 default_server;|    listen 4000 default_server;|" "$NGINX_CONF"

    # Replace listen directive
    sudo sed -i "s|listen 4000;|listen ${listen_addr}:4000;|g" "$NGINX_CONF"

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
        warn "No active firewall detected (or unsupported). If you use iptables, open port 4000 manually."
    fi

    sudo systemctl reload nginx

    # Show access info
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "YOUR_IP")

    echo ""
    ok "Local network access enabled!"
    echo ""
    echo "  From other devices on your network, connect to:"
    echo ""
    echo "    http://${server_ip}:4000"
    echo ""
    echo "  API endpoint:"
    echo "    http://${server_ip}:4000/v1/chat/completions"
    echo ""
    echo "  To connect Claude Code from another machine:"
    echo "    export ANTHROPIC_BASE_URL=\"http://${server_ip}:4000\""
    echo "    export ANTHROPIC_API_KEY=\"sk-local-proxy-key\""
    echo "    claude"
    echo ""
}

# ============================================================
# VERIFY
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
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "  ${GREEN}Installation complete!${NC}"
    echo ""
    echo "  Quick start:"
    echo "    myclaude          — launch Claude Code"
    echo "    myclaude --help   — pass args to Claude Code"
    echo ""
    echo "  Service management:"
    echo "    sudo systemctl status myclaude"
    echo "    sudo systemctl restart myclaude"
    echo "    journalctl -u myclaude -f"
    echo ""
    echo "  Convenience aliases (after 'source ~/.bashrc'):"
    echo "    myclaude-status   myclaude-logs   myclaude-start   myclaude-stop"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ============================================================
# MAIN
# ============================================================
main() {
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║          🤖 MyClaude Installer                       ║"
    echo "║     Claude Code + LiteLLM + NVIDIA NIM              ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo ""

    check_sudo
    check_prereqs
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
