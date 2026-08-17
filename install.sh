#!/bin/bash
set -euo pipefail

# ============================================================
# MyClaude - TUI Installer
# Claude Code + LiteLLM + NVIDIA NIM Proxy
# ============================================================

# Get repo directory
set +u
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "bash" ]; then
    SRC="${BASH_SOURCE[0]}"
else
    SRC=""
fi
set -u

if [ -n "$SRC" ]; then
    REPO_DIR="$(cd "$(dirname "$SRC")" && pwd)"
else
    REPO_DIR="${PWD}"
    if [ ! -f "$REPO_DIR/install.sh" ] || [ ! -f "$REPO_DIR/config.yaml" ]; then
        REPO_DIR="/tmp/myclaude-install-$$"
        git clone --depth 1 https://github.com/S-V-J/myclaude.git "$REPO_DIR" >/dev/null 2>&1
    fi
fi

SERVICE_NAME="myclaude"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"
VENV_DIR="$REPO_DIR/venv"
SERVICE_USER="myclaude"

# Detect OS and package manager
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-}"
    else
        OS_ID="unknown"
    fi

    if command -v apt &>/dev/null; then
        PKG_MGR="apt"
    elif command -v dnf &>/dev/null; then
        PKG_MGR="dnf"
    elif command -v yum &>/dev/null; then
        PKG_MGR="yum"
    elif command -v pacman &>/dev/null; then
        PKG_MGR="pacman"
    elif command -v zypper &>/dev/null; then
        PKG_MGR="zypper"
    else
        PKG_MGR="unknown"
    fi
}

# Check if running in WSL
is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null || grep -qi wsl /proc/version 2>/dev/null
}

# Check for TTY (interactive terminal)
has_tty() {
    [ -t 0 ] && [ -t 1 ]
}

# Check for whiptail/dialog
check_tui() {
    if command -v whiptail &>/dev/null; then
        echo "whiptail"
    elif command -v dialog &>/dev/null; then
        echo "dialog"
    else
        echo "none"
    fi
}

# Parse command line arguments
FORCE_TERMINAL=false
for arg in "$@"; do
    case "$arg" in
        --terminal) FORCE_TERMINAL=true ;;
        --auto) ;;
        *) ;;
    esac
done

TUI_TOOL=$(check_tui)
USE_TUI=false
if [ "$FORCE_TERMINAL" = true ]; then
    USE_TUI=false
    echo "=== Running in terminal mode (--terminal) ==="
elif [ "$TUI_TOOL" != "none" ] && has_tty; then
    USE_TUI=true
fi

# ============================================================
# Terminal/TUI helper functions
# ============================================================
# For terminal mode, we print clean prompts and read input
term_msgbox() {
    local msg="$1"
    echo -e "\n============================================"
    echo "$msg" | sed 's/\\n/\n/g'
    echo "============================================"
    read -rp "Press Enter to continue..." _
}

term_inputbox() {
    local prompt="$1"
    local default="$2"
    echo -e "\n$prompt" | sed 's/\\n/\n/g'
    read -rp "[$default]: " input
    echo "${input:-$default}"
}

term_passwordbox() {
    local prompt="$1"
    echo -e "\n$prompt" | sed 's/\\n/\n/g'
    # Read password - use stdin directly
    read -rsp "> " input
    echo
    echo "$input"
}

term_yesno() {
    local prompt="$1"
    echo -e "\n$prompt" | sed 's/\\n/\n/g'
    while true; do
        read -rp "(y/N): " ans
        case "$ans" in
            [Yy]*) return 0 ;;
            [Nn]*|"") return 1 ;;
            *) echo "Please answer y or n." ;;
        esac
    done
}

term_checklist() {
    local prompt="$1"
    local items="$2"
    echo -e "\n$prompt" | sed 's/\\n/\n/g'
    local selected=""
    for item in $items; do
        item=$(echo "$item" | tr -d '"')
        if term_yesno "Enable $item?"; then
            selected="$selected $item"
        fi
    done
    echo "$selected"
}

term_gauge() {
    local msg="$1"
    echo "$msg"
    cat  # consume stdin
}

# Logging functions
log_info() { echo -e "\n[INFO] $*"; }
log_success() { echo -e "\n[SUCCESS] $*"; }
log_warn() { echo -e "\n[WARN] $*"; }
log_error() { echo -e "\n[ERROR] $*"; }

# Unified functions that work in both TUI and terminal mode
ui_msgbox() {
    if [ "$USE_TUI" = true ]; then
        impl_msgbox "$@"
    else
        term_msgbox "$@"
    fi
}

ui_inputbox() {
    if [ "$USE_TUI" = true ]; then
        impl_inputbox "$@"
    else
        term_inputbox "$@"
    fi
}

ui_passwordbox() {
    if [ "$USE_TUI" = true ]; then
        impl_passwordbox "$@"
    else
        term_passwordbox "$@"
    fi
}

ui_yesno() {
    if [ "$USE_TUI" = true ]; then
        impl_yesno "$@"
    else
        term_yesno "$@"
    fi
}

ui_checklist() {
    if [ "$USE_TUI" = true ]; then
        impl_checklist "$@"
    else
        term_checklist "$@"
    fi
}

ui_gauge() {
    if [ "$USE_TUI" = true ]; then
        impl_gauge "$@"
    else
        term_gauge "$@"
    fi
}

# TUI implementation functions (for when USE_TUI=true)
impl_msgbox() {
    local msg="$1"
    local height="${2:-12}"
    local width="${3:-70}"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --msgbox "$msg" "$height" "$width"
    else
        dialog --title "MyClaude Installer" --msgbox "$msg" "$height" "$width"
    fi
}

impl_inputbox() {
    local prompt="$1"
    local default="$2"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --inputbox "$prompt" 12 70 "$default" 3>&1 1>&2 2>&3
    else
        dialog --title "MyClaude Installer" --inputbox "$prompt" 12 70 "$default" 3>&1 1>&2 2>&3
    fi
}

impl_passwordbox() {
    local prompt="$1"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --passwordbox "$prompt" 12 70 3>&1 1>&2 2>&3
    else
        dialog --title "MyClaude Installer" --passwordbox "$prompt" 12 70 3>&1 1>&2 2>&3
    fi
}

impl_yesno() {
    local prompt="$1"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --yesno "$prompt" 12 70
    else
        dialog --title "MyClaude Installer" --yesno "$prompt" 12 70
    fi
}

impl_checklist() {
    local prompt="$1"
    local items="$2"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --checklist "$prompt" 20 70 10 $items 3>&1 1>&2 2>&3
    else
        dialog --title "MyClaude Installer" --checklist "$prompt" 20 70 10 $items 3>&1 1>&2 2>&3
    fi
}

impl_gauge() {
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --gauge "$1" 10 70 0
    else
        dialog --title "MyClaude Installer" --gauge "$1" 10 70 0
    fi
}

ui_checklist() {
    local prompt="$1"
    local items="$2"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --checklist "$prompt" 20 70 10 $items 3>&1 1>&2 2>&3
    else
        dialog --title "MyClaude Installer" --checklist "$prompt" 20 70 10 $items 3>&1 1>&2 2>&3
    fi
}

ui_gauge() {
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --gauge "$1" 10 70 0
    else
        dialog --title "MyClaude Installer" --gauge "$1" 10 70 0
    fi
}

# ============================================================
# System package installation
# ============================================================
install_system_packages() {
    detect_os

    case "$PKG_MGR" in
        apt)
            sudo apt update -y
            sudo apt install -y nginx python3 python3-venv python3-pip curl git whiptail 2>/dev/null || true
            # Install whiptail for TUI if not present
            if ! command -v whiptail &>/dev/null; then
                sudo apt install -y whiptail 2>/dev/null || true
            fi
            ;;
        dnf)
            sudo dnf install -y nginx python3 python3-venv python3-pip curl git newt 2>/dev/null || true
            ;;
        yum)
            sudo yum install -y nginx python3 python3-venv python3-pip curl git newt 2>/dev/null || true
            ;;
        pacman)
            sudo pacman -Sy --noconfirm nginx python python-pip curl git libnewt 2>/dev/null || true
            ;;
        zypper)
            sudo zypper install -y nginx python3 python3-venv python3-pip curl git python3-newt 2>/dev/null || true
            ;;
        *)
            echo "WARNING: Unknown package manager. Please install manually: nginx python3 python3-venv python3-pip curl git"
            ;;
    esac

    # Ensure whiptail/dialog is available for TUI
    if ! command -v whiptail &>/dev/null && ! command -v dialog &>/dev/null; then
        USE_TUI=false
    fi
}

# ============================================================
# STEP 1: API Keys (TUI)
# ============================================================
step1_api_keys() {
    ui_msgbox "Step 1 of 4: API Keys\n\nYou need at least one NVIDIA NIM API key.\nGet free keys at: https://build.nvidia.com\n\nYou can configure up to 4 keys for different model providers."

    # Key 1 - Required
    while true; do
        NVIDIA_API_KEY=$(ui_passwordbox "Key 1: Primary NVIDIA (Required)\n\nEnter your NVIDIA NIM API key (nvapi-...):" "")
        if [ -n "$NVIDIA_API_KEY" ]; then
            break
        fi
        ui_msgbox "API key cannot be empty. Please try again."
    done

    # Key 2 - Optional
    NEMOTRON_SUPER_API_KEY=$(ui_passwordbox "Key 2: Nemotron Super (Optional)\n\nEnter API key for nemotron-3-super (press Enter to skip, falls back to Key 1):" "")

    # Key 3 - Optional
    MINIMAX_API_KEY=$(ui_passwordbox "Key 3: Minimax (Optional)\n\nEnter Minimax API key for minimax-m3 (press Enter to skip, falls back to Key 1):" "")

    # Key 4 - Optional
    STEPFUN_API_KEY=$(ui_passwordbox "Key 4: StepFun (Optional)\n\nEnter StepFun API key for step-3.7-flash (press Enter to skip, falls back to Key 1):" "")

    # Validate keys by testing
    if ui_yesno "Test API keys now? (Recommended)"; then
        test_keys
    fi

    return 0
}

test_keys() {
    echo "Testing API keys..."

    local test_result

    # Test NVIDIA key (Nemotron 3 Ultra)
    echo -n "  Key 1 (NVIDIA - Nemotron 3 Ultra): "
    test_result=$(curl -s --max-time 15 \
        -H "Authorization: Bearer $NVIDIA_API_KEY" \
        -H "Content-Type: application/json" \
        -X POST https://integrate.api.nvidia.com/v1/chat/completions \
        -d '{"model":"nvidia/nemotron-3-ultra-550b-a55b","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

    if echo "$test_result" | grep -q "choices\|content"; then
        echo "✓ Valid"
    else
        echo "✗ Invalid or rate limited"
        echo "    $test_result"
    fi

    # Test Nemotron Super if provided
    if [ -n "$NEMOTRON_SUPER_API_KEY" ]; then
        echo -n "  Key 2 (Nemotron Super): "
        test_result=$(curl -s --max-time 15 \
            -H "Authorization: Bearer $NEMOTRON_SUPER_API_KEY" \
            -H "Content-Type: application/json" \
            -X POST https://integrate.api.nvidia.com/v1/chat/completions \
            -d '{"model":"nvidia/nemotron-3-super-120b-a12b","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

        if echo "$test_result" | grep -q "choices\|content"; then
            echo "✓ Valid"
        else
            echo "✗ Invalid or rate limited"
        fi
    fi

    # Test Minimax if provided
    if [ -n "$MINIMAX_API_KEY" ]; then
        echo -n "  Key 3 (Minimax M3): "
        test_result=$(curl -s --max-time 15 \
            -H "Authorization: Bearer $MINIMAX_API_KEY" \
            -H "Content-Type: application/json" \
            -X POST https://integrate.api.nvidia.com/v1/chat/completions \
            -d '{"model":"minimaxai/minimax-m3","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

        if echo "$test_result" | grep -q "choices\|content"; then
            echo "✓ Valid"
        else
            echo "✗ Invalid or rate limited"
        fi
    fi

    # Test StepFun if provided
    if [ -n "$STEPFUN_API_KEY" ]; then
        echo -n "  Key 4 (StepFun Step-3.7-Flash): "
        test_result=$(curl -s --max-time 15 \
            -H "Authorization: Bearer $STEPFUN_API_KEY" \
            -H "Content-Type: application/json" \
            -X POST https://integrate.api.nvidia.com/v1/chat/completions \
            -d '{"model":"stepfun-ai/step-3.7-flash","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

        if echo "$test_result" | grep -q "choices\|content"; then
            echo "✓ Valid"
        else
            echo "✗ Invalid or rate limited"
        fi
    fi

    echo ""
    read -rp "Press Enter to continue..." _
}

# ============================================================
# STEP 2: Model Mapping (TUI)
# ============================================================
step2_model_mapping() {
    ui_msgbox "Step 2 of 4: Model Mapping\n\nMap each Claude Code model to an NVIDIA backend.\n\nCurrent defaults:\n• claude-opus-5 → nemotron-3-ultra (Key 1)\n• claude-sonnet-5 → nemotron-3-super (Key 2)\n• claude-sonnet-5-1m → minimax-m3 (Key 3)\n• claude-haiku-4-5 → step-3.7-flash (Key 4)"

    # For now, use defaults. Advanced users can edit config.yaml later
    if ui_yesno "Use default model mapping?\n\n(You can customize later by editing config.yaml)"; then
        return 0
    fi

    # Custom mapping - simplified for TUI
    ui_msgbox "Custom mapping selected.\n\nAfter installation, edit config.yaml to customize:\n  $REPO_DIR/config.yaml\n\nEach model entry has:\n  - model_name: claude-opus-5\n  - litellm_params.model: nvidia_nim/...\n  - litellm_params.api_key: os.environ/..."

    return 0
}

# ============================================================
# STEP 3: Advanced Options (TUI)
# ============================================================
step3_advanced() {
    ui_msgbox "Step 3 of 4: Advanced Options"

    local options
    options=$(ui_checklist "Select advanced options:" \
        "lan" "Enable LAN Access (0.0.0.0:4000 + firewall)" OFF \
        "tls" "Enable TLS/SSL (HTTPS on port 4443)" OFF \
        "logging" "Enable request/response logging" OFF \
        "custom_limits" "Custom nginx rate limits" OFF \
        "custom_timeouts" "Custom timeouts" OFF)

    ENABLE_LAN=false
    ENABLE_TLS=false
    ENABLE_LOGGING=false
    CUSTOM_LIMITS=false
    CUSTOM_TIMEOUTS=false

    for opt in $options; do
        opt=$(echo "$opt" | tr -d '"')
        case "$opt" in
            lan) ENABLE_LAN=true ;;
            tls) ENABLE_TLS=true ;;
            logging) ENABLE_LOGGING=true ;;
            custom_limits) CUSTOM_LIMITS=true ;;
            custom_timeouts) CUSTOM_TIMEOUTS=true ;;
        esac
    done

    if [ "$CUSTOM_LIMITS" = true ]; then
        NGINX_RATE=$(ui_inputbox "Nginx rate limit (req/s):" "16")
        NGINX_BURST=$(ui_inputbox "Nginx burst limit:" "32")
    else
        NGINX_RATE=16
        NGINX_BURST=32
    fi

    if [ "$CUSTOM_TIMEOUTS" = true ]; then
        REQUEST_TIMEOUT=$(ui_inputbox "Request timeout (seconds):" "3600")
    else
        REQUEST_TIMEOUT=3600
    fi

    # TLS domain input
    if [ "$ENABLE_TLS" = true ]; then
        TLS_DOMAIN=$(ui_inputbox "Domain for TLS cert (e.g., myclaude.local):" "localhost")
        TLS_ENABLE_HTTP=$(ui_yesno "Also keep HTTP on port 4000? (Recommended for local access)" && echo "true" || echo "false")
    else
        TLS_DOMAIN="localhost"
        TLS_ENABLE_HTTP="true"
    fi

    return 0
}

# ============================================================
# STEP 4: Raw Payload Validation (TUI)
# ============================================================
step4_payload() {
    ui_msgbox "Step 4 of 4: Raw Payload Validation\n\nYou can customize the JSON payload sent to NVIDIA for each model.\n\nDefaults are optimized for each model. Advanced users can edit after installation."

    if ui_yesno "View default payload for claude-opus-5?"; then
        cat > /tmp/payload_example.json <<'EOF'
{
  "model": "nvidia/nemotron-3-ultra-550b-a55b",
  "messages": [{"role": "user", "content": "{{PROMPT}}"}],
  "temperature": 1.0,
  "top_p": 0.95,
  "max_tokens": 16384,
  "seed": 42,
  "stream": false,
  "extra_body": {
    "chat_template_kwargs": {"enable_thinking": true},
    "reasoning_budget": 16384
  }
}
EOF
        if [ "$TUI_TOOL" = "whiptail" ]; then
            whiptail --title "Default Payload" --textbox /tmp/payload_example.json 20 80
        else
            dialog --title "Default Payload" --textbox /tmp/payload_example.json 20 80
        fi
    fi

    return 0
}

# ============================================================
# INSTALLATION EXECUTION
# ============================================================
run_installation() {
    {
        echo 5; echo "# Checking sudo..."; sleep 1
        sudo -v

        echo 10; echo "# Installing system packages..."; sleep 1
        install_system_packages

        echo 20; echo "# Setting up API keys..."; sleep 1
        write_env_file

        echo 30; echo "# Setting up system user..."; sleep 1
        setup_system_user

        echo 40; echo "# Creating virtual environment..."; sleep 1
        setup_venv

        echo 50; echo "# Configuring nginx..."; sleep 1
        setup_nginx

        echo 55; echo "# Setting up log rotation..."; sleep 1
        setup_logrotate

        echo 60; echo "# Setting up systemd service..."; sleep 1
        setup_systemd

        echo 65; echo "# Setting up TLS/SSL..."; sleep 1
        setup_tls

        echo 70; echo "# Installing Claude Code..."; sleep 1
        setup_claude_code

        echo 80; echo "# Setting up aliases..."; sleep 1
        setup_bashrc

        echo 85; echo "# Installing wrapper..."; sleep 1
        setup_wrapper

        echo 90; echo "# Configuring LAN access..."; sleep 1
        setup_lan_hosting

        echo 95; echo "# Verification..."; sleep 1
        verify
    } | ui_gauge "Installing MyClaude..."
}

# ============================================================
# ORIGINAL INSTALL FUNCTIONS (adapted for TUI)
# ============================================================

write_env_file() {
    LOCAL_KEY="sk-local-$(openssl rand -hex 16 2>/dev/null || echo "proxykey$(date +%s)")"
    cat > "$REPO_DIR/.env" <<ENVEOF
# MyClaude Environment Configuration
NVIDIA_API_KEY="$NVIDIA_API_KEY"
ENVEOF
    if [ -n "${NEMOTRON_SUPER_API_KEY:-}" ]; then
        echo "NEMOTRON_SUPER_API_KEY=\"$NEMOTRON_SUPER_API_KEY\"" >> "$REPO_DIR/.env"
    fi
    if [ -n "${MINIMAX_API_KEY:-}" ]; then
        echo "MINIMAX_API_KEY=\"$MINIMAX_API_KEY\"" >> "$REPO_DIR/.env"
    fi
    if [ -n "${STEPFUN_API_KEY:-}" ]; then
        echo "STEPFUN_API_KEY=\"$STEPFUN_API_KEY\"" >> "$REPO_DIR/.env"
    fi
    echo "LITELLM_MASTER_KEY=\"$LOCAL_KEY\"" >> "$REPO_DIR/.env"
    echo "LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=\"true\"" >> "$REPO_DIR/.env"
}

setup_system_user() {
    if id "$SERVICE_USER" &>/dev/null; then
        if [ "$USE_TUI" = true ]; then
            if ui_yesno "User '$SERVICE_USER' already exists. Re-create it?"; then
                sudo userdel -r "$SERVICE_USER" 2>/dev/null || true
                sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
            fi
        else
            # In --auto mode, just ensure user exists
            echo "User $SERVICE_USER exists, keeping it."
        fi
    else
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    fi
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true
}

setup_venv() {
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true

    # Determine which user to create venv as
    if sudo -u "$SERVICE_USER" test -w "$REPO_DIR" 2>/dev/null; then
        VENV_AS_USER="$SERVICE_USER"
    else
        # Fallback: find a suitable user
        VENV_AS_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
        if [ "$VENV_AS_USER" = "root" ] || [ -z "$VENV_AS_USER" ]; then
            VENV_AS_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)
        fi
        if [ -z "$VENV_AS_USER" ] || [ "$VENV_AS_USER" = "root" ]; then
            VENV_AS_USER="${USER:-$(id -un)}"
        fi
        if [ -z "$VENV_AS_USER" ] || [ "$VENV_AS_USER" = "root" ]; then
            VENV_AS_USER="$SERVICE_USER"
        fi
        sudo chown -R "$VENV_AS_USER:$VENV_AS_USER" "$REPO_DIR" 2>/dev/null || true
    fi

    if [ ! -d "$VENV_DIR" ]; then
        sudo -u "$VENV_AS_USER" python3 -m venv "$VENV_DIR"
    fi

    # Ensure service user owns venv for systemd
    if [ "$VENV_AS_USER" != "$SERVICE_USER" ]; then
        sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR" 2>/dev/null || true
    fi

    # Install packages
    sudo -u "$VENV_AS_USER" "$VENV_DIR/bin/pip" install --upgrade pip --quiet 2>/dev/null || true
    sudo -u "$VENV_AS_USER" "$VENV_DIR/bin/pip" install 'litellm[proxy]' "fastapi<0.140.0" --quiet
}

setup_nginx() {
    sudo rm -f "$NGINX_CONF"
    sudo cp "$REPO_DIR/nginx-myclaude.conf" "$NGINX_CONF"

    if [ "$ENABLE_LAN" = true ]; then
        sudo sed -i 's|^listen 4000;|listen 0.0.0.0:4000;|g' "$NGINX_CONF"
        sudo sed -i 's|^listen 4000 default_server;|listen 0.0.0.0:4000 default_server;|g' "$NGINX_CONF"
    fi

    # Add rate limiting zone to nginx.conf http block if not present
    if ! grep -q "limit_req_zone.*myclaude" /etc/nginx/nginx.conf 2>/dev/null; then
        sudo sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=myclaude:10m rate=16r/s;' /etc/nginx/nginx.conf
    fi

    # Rate limiting is now explicit in nginx-myclaude.conf template
    # Only update rate/burst values if custom limits provided
    if [ -n "${NGINX_RATE:-}" ] && [ -n "${NGINX_BURST:-}" ]; then
        sudo sed -i "s|rate=16r/s|rate=${NGINX_RATE}r/s|g" /etc/nginx/nginx.conf
        sudo sed -i "s|burst=32|burst=${NGINX_BURST}|g" "$NGINX_CONF"
    fi

    if sudo nginx -t 2>&1 | grep -q "successful"; then
        sudo systemctl reload nginx
    else
        ui_msgbox "Nginx config test failed. Check $NGINX_CONF"
        exit 1
    fi
}

setup_logrotate() {
    if [ -f "$REPO_DIR/logrotate-myclaude" ]; then
        sudo cp "$REPO_DIR/logrotate-myclaude" /etc/logrotate.d/myclaude
        # Update paths in logrotate config to match actual repo directory
        sudo sed -i "s|/home/ML/myclaude|$REPO_DIR|g" /etc/logrotate.d/myclaude
        # Ensure log file exists with correct permissions
        sudo touch "$REPO_DIR/litellm.log"
        sudo chown "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR/litellm.log"
    fi
}

setup_systemd() {
    sudo chown "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR/.env" 2>/dev/null || true
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$VENV_DIR" 2>/dev/null || true

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
    if ! sudo systemctl is-active --quiet "$SERVICE_NAME"; then
        ui_msgbox "myclaude.service failed to start.\nCheck: journalctl -u $SERVICE_NAME -n 20"
        exit 1
    fi
}

setup_claude_code() {
    if command -v claude &>/dev/null; then
        return 0
    fi

    if [ "$USE_TUI" = true ]; then
        if ! ui_yesno "Claude Code not found. Install now?"; then
            return 0
        fi
    else
        echo "Claude Code not found, installing..."
    fi

    if command -v npm &>/dev/null; then
        npm install -g @anthropic-ai/claude-code
    else
        if [ "$USE_TUI" = true ]; then
            ui_msgbox "npm not found. Install Node.js first, then run:\nnpm install -g @anthropic-ai/claude-code"
        else
            echo "npm not found. Please install Node.js and run: npm install -g @anthropic-ai/claude-code"
        fi
    fi
}

setup_bashrc() {
    local bashrc="$HOME/.bashrc"
    local marker="# >>> MyClaude >>>"

    if ! grep -qF "$marker" "$bashrc" 2>/dev/null; then
        cat >> "$bashrc" <<'BASHEOF'

# >>> MyClaude >>>
alias myclaude-start='sudo systemctl start myclaude'
alias myclaude-stop='sudo systemctl stop myclaude'
alias myclaude-status='sudo systemctl status myclaude'
alias myclaude-logs='journalctl -u myclaude -f'
# <<< MyClaude <<<
BASHEOF
    fi
}

setup_wrapper() {
    cat > /tmp/myclaude_wrapper <<'WRAPEOF'
#!/bin/bash
# myclaude wrapper — launches Claude Code through the LiteLLM proxy
# Installed to /usr/local/bin/myclaude by install.sh

SERVICE_NAME="myclaude"
NGINX_CONF="/etc/nginx/sites-enabled/myclaude"

# Check if service is active, start if not
if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "Starting MyClaude proxy..."
    sudo systemctl start "$SERVICE_NAME"
    sleep 3
    if ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo "Failed to start. Check: journalctl -u $SERVICE_NAME -n 20"
        exit 1
    fi
fi

# Detect if TLS is enabled (check nginx config for port 4443)
if grep -q "listen 4443" "$NGINX_CONF" 2>/dev/null; then
    export ANTHROPIC_BASE_URL="https://localhost:4443"
    export ANTHROPIC_API_KEY="sk-local-proxy-key"
    echo "Launching Claude Code via MyClaude proxy (HTTPS)..."
else
    export ANTHROPIC_BASE_URL="http://localhost:4000"
    export ANTHROPIC_API_KEY="sk-local-proxy-key"
    echo "Launching Claude Code via MyClaude proxy (HTTP)..."
fi

exec claude "$@"
WRAPEOF

    sudo cp /tmp/myclaude_wrapper /usr/local/bin/myclaude
    sudo chmod +x /usr/local/bin/myclaude
    rm -f /tmp/myclaude_wrapper
}

setup_tls() {
    if [ "$ENABLE_TLS" = true ]; then
        log_info "Setting up TLS/SSL..."
        # Use the setup-tls.sh script
        if [ -f "$REPO_DIR/setup-tls.sh" ]; then
            bash "$REPO_DIR/setup-tls.sh" generate "$TLS_DOMAIN" "$TLS_ENABLE_HTTP"
        else
            ui_msgbox "WARNING: setup-tls.sh not found. TLS not configured."
        fi
    fi
}

setup_lan_hosting() {
    if [ "$ENABLE_LAN" = true ]; then
        local ports="4000"
        if [ "$ENABLE_TLS" = true ]; then
            ports="4000 4443"
        fi

        for port in $ports; do
            if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
                sudo ufw allow "$port"/tcp comment "MyClaude proxy"
            elif command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then
                sudo firewall-cmd --permanent --add-port="$port"/tcp 2>/dev/null || true
                sudo firewall-cmd --reload 2>/dev/null || true
            elif command -v iptables &>/dev/null; then
                sudo iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null || true
            fi
        done
        sudo systemctl reload nginx
    fi
}

verify() {
    # Test HTTP
    if ! ss -tlnp 2>/dev/null | grep -q ':4000 '; then
        ui_msgbox "ERROR: Nginx NOT on port 4000"
        exit 1
    fi
    if ! ss -tlnp 2>/dev/null | grep -q ':4001 '; then
        ui_msgbox "ERROR: LiteLLM NOT on port 4001"
        exit 1
    fi

    local test_result
    test_result=$(curl -s --max-time 15 \
        -H "Authorization: Bearer sk-local-proxy-key" \
        -H "Content-Type: application/json" \
        -X POST http://localhost:4000/v1/chat/completions \
        -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

    if ! echo "$test_result" | grep -q "choices\|content"; then
        ui_msgbox "WARNING: Proxy test returned unexpected result:\n$test_result"
    fi

    # Test HTTPS if TLS enabled
    if [ "$ENABLE_TLS" = true ]; then
        if ! ss -tlnp 2>/dev/null | grep -q ':4443 '; then
            ui_msgbox "WARNING: HTTPS NOT on port 4443"
        else
            test_result=$(curl -k -s --max-time 15 \
                -H "Authorization: Bearer sk-local-proxy-key" \
                -H "Content-Type: application/json" \
                -X POST https://localhost:4443/v1/chat/completions \
                -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

            if ! echo "$test_result" | grep -q "choices\|content"; then
                ui_msgbox "WARNING: HTTPS proxy test returned unexpected result:\n$test_result"
            fi
        fi
    fi
}

# ============================================================
# MAIN TUI FLOW
# ============================================================
main() {
    cd "$REPO_DIR"

    # Welcome screen
    if ! ui_yesno "Welcome to MyClaude Installer\n\nThis will set up:\n• nginx reverse proxy (port 4000)\n• LiteLLM proxy (port 4001)\n• NVIDIA NIM model routing\n• systemd service\n• myclaude command wrapper\n\nContinue?"; then
        echo "Installation cancelled."
        exit 0
    fi

    # Step 1: API Keys
    step1_api_keys

    # Step 2: Model Mapping
    step2_model_mapping

    # Step 3: Advanced Options
    step3_advanced

    # Step 4: Payload Validation
    step4_payload

    # Confirm installation
    if ! ui_yesno "Ready to install MyClaude?\n\nThis will:\n• Install system packages (nginx, python3-venv)\n• Create system user 'myclaude'\n• Set up Python venv + LiteLLM\n• Configure nginx + systemd\n• Install myclaude wrapper command\n\nProceed?"; then
        echo "Installation cancelled."
        exit 0
    fi

    # Run installation
    run_installation

    # Success
    ui_msgbox "Installation Complete!\n\nQuick start:\n  myclaude              # launch Claude Code\n  myclaude --help       # pass args to Claude Code\n\nService management:\n  sudo systemctl status myclaude\n  sudo systemctl restart myclaude\n  journalctl -u myclaude -f\n\nConvenience aliases (run 'source ~/.bashrc'):\n  myclaude-status  myclaude-logs  myclaude-start  myclaude-stop"
}

# Handle --auto mode for non-interactive
if [[ "${1:-}" == "--auto" ]]; then
    # Use environment variables
    NVIDIA_API_KEY="${NVIDIA_API_KEY:-}"
    NEMOTRON_SUPER_API_KEY="${NEMOTRON_SUPER_API_KEY:-}"
    MINIMAX_API_KEY="${MINIMAX_API_KEY:-}"
    STEPFUN_API_KEY="${STEPFUN_API_KEY:-}"
    ENABLE_LAN="${ENABLE_LAN:-false}"
    ENABLE_TLS="${ENABLE_TLS:-false}"
    TLS_DOMAIN="${TLS_DOMAIN:-localhost}"
    TLS_ENABLE_HTTP="${TLS_ENABLE_HTTP:-true}"
    NGINX_RATE="${NGINX_RATE:-16}"
    NGINX_BURST="${NGINX_BURST:-32}"
    REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-3600}"

    if [ -z "$NVIDIA_API_KEY" ]; then
        echo "ERROR: NVIDIA_API_KEY required for --auto mode"
        exit 1
    fi

    # Set USE_TUI to false for auto mode
    USE_TUI=false

    # Run without TUI
    install_system_packages
    write_env_file
    setup_system_user
    setup_venv
    setup_nginx
    setup_logrotate
    setup_systemd
    setup_tls
    setup_claude_code
    setup_bashrc
    setup_wrapper
    setup_lan_hosting
    verify

    echo "Auto installation complete!"
    echo "Run 'myclaude' to start Claude Code"
    exit 0
fi

# Run TUI main
main "$@"