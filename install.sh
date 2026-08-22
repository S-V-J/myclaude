#!/bin/bash
set -euo pipefail

# ============================================================
# MyClaude - Terminal Installer
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

# Use the installing user as the service user (not a dedicated myclaude user)
# This allows the system to work for any user without creating a dedicated service user
SERVICE_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
# Ensure we don't run as root
if [ "$SERVICE_USER" = "root" ] || [ -z "$SERVICE_USER" ]; then
    SERVICE_USER=$(awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd)
fi
if [ -z "$SERVICE_USER" ] || [ "$SERVICE_USER" = "root" ]; then
    SERVICE_USER="${USER:-$(id -un)}"
fi

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

# Logging functions
log_info() { echo -e "\n[INFO] $*"; }
log_success() { echo -e "\n[SUCCESS] $*"; }
log_warn() { echo -e "\n[WARN] $*"; }
log_error() { echo -e "\n[ERROR] $*"; }

# Terminal helper functions
msgbox() {
    local msg="$1"
    echo -e "\n============================================"
    echo "$msg" | sed 's/\\n/\n/g'
    echo "============================================"
    read -rp "Press Enter to continue..." _
}

inputbox() {
    local prompt="$1"
    local default="$2"
    echo -e "\n$prompt" | sed 's/\\n/\n/g'
    read -rp "[$default]: " input
    echo "${input:-$default}"
}

passwordbox() {
    local prompt="$1"
    echo -e "\n$prompt" | sed 's/\\n/\n/g'
    # Read password - use stdin directly
    read -rsp "> " input
    echo
    echo "$input"
}

yesno() {
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

checklist() {
    local prompt="$1"
    local items="$2"
    echo -e "\n$prompt" | sed 's/\\n/\n/g'
    local selected=""
    for item in $items; do
        item=$(echo "$item" | tr -d '"')
        if yesno "Enable $item?"; then
            selected="$selected $item"
        fi
    done
    echo "$selected"
}

gauge() {
    local msg="$1"
    echo "$msg"
    cat  # consume stdin
}

# ============================================================
# System package installation
# ============================================================
install_system_packages() {
    detect_os

    case "$PKG_MGR" in
        apt)
            sudo apt update -y
            sudo apt install -y nginx python3 python3-venv python3-pip curl git 2>/dev/null || true
            ;;
        dnf)
            sudo dnf install -y nginx python3 python3-venv python3-pip curl git 2>/dev/null || true
            ;;
        yum)
            sudo yum install -y nginx python3 python3-venv python3-pip curl git 2>/dev/null || true
            ;;
        pacman)
            sudo pacman -Sy --noconfirm nginx python python-pip curl git 2>/dev/null || true
            ;;
        zypper)
            sudo zypper install -y nginx python3 python3-venv python3-pip curl git 2>/dev/null || true
            ;;
        *)
            echo "WARNING: Unknown package manager. Please install manually: nginx python3 python3-venv python3-pip curl git"
            ;;
    esac
}

# ============================================================
# STEP 1: API Keys
# ============================================================
step1_api_keys() {
    echo ""
    echo "============================================"
    echo "Step 1 of 4: API Keys"
    echo "You need at least one NVIDIA NIM API key."
    echo "Get free keys at: https://build.nvidia.com"
    echo "All 4 models use Nemotron 3 Ultra. You can configure up to 4 keys for load isolation (80 RPM combined)."
    echo "============================================"

    # Key 1 - Required
    while true; do
        echo -e "\nKey 1: Primary NVIDIA (Required)"
        echo "Enter your NVIDIA NIM API key for Nemotron 3 Ultra (nvapi-...):"
        read -rsp "> " NVIDIA_API_KEY_PROJECT_1
        echo
        if [ -n "$NVIDIA_API_KEY_PROJECT_1" ]; then
            break
        fi
        echo "API key cannot be empty. Please try again."
    done

    # Key 2 - Optional
    echo -e "\nKey 2: Nemotron Ultra - Project 2 (Optional)"
    echo "Enter API key for load isolation (press Enter to skip, falls back to Key 1):"
    read -rsp "> " NVIDIA_API_KEY_PROJECT_2
    echo

    # Key 3 - Optional
    echo -e "\nKey 3: Nemotron Ultra - Project 3 (Optional)"
    echo "Enter API key for load isolation (press Enter to skip, falls back to Key 1):"
    read -rsp "> " NVIDIA_API_KEY_PROJECT_3
    echo

    # Key 4 - Optional
    echo -e "\nKey 4: Nemotron Ultra - Project 4 (Optional)"
    echo "Enter API key for load isolation (press Enter to skip, falls back to Key 1):"
    read -rsp "> " NVIDIA_API_KEY_PROJECT_4
    echo

    # Validate keys by testing
    if yesno "Test API keys now? (Recommended)"; then
        test_keys
    fi

    return 0
}

test_keys() {
    echo "Testing API keys (all Nemotron 3 Ultra)..."

    local test_result

    # Test Key 1 (Nemotron 3 Ultra)
    echo -n "  Key 1 (PROJECT_1 - Nemotron 3 Ultra): "
    test_result=$(curl -s --max-time 15 \
        -H "Authorization: Bearer $NVIDIA_API_KEY_PROJECT_1" \
        -H "Content-Type: application/json" \
        -X POST https://integrate.api.nvidia.com/v1/chat/completions \
        -d '{"model":"nvidia/nemotron-3-ultra-550b-a55b","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

    if echo "$test_result" | grep -q "choices\|content"; then
        echo "✓ Valid"
    else
        echo "✗ Invalid or rate limited"
        echo "    $test_result"
    fi

    # Test Key 2 if provided
    if [ -n "$NVIDIA_API_KEY_PROJECT_2" ]; then
        echo -n "  Key 2 (PROJECT_2 - Nemotron 3 Ultra): "
        test_result=$(curl -s --max-time 15 \
            -H "Authorization: Bearer $NVIDIA_API_KEY_PROJECT_2" \
            -H "Content-Type: application/json" \
            -X POST https://integrate.api.nvidia.com/v1/chat/completions \
            -d '{"model":"nvidia/nemotron-3-ultra-550b-a55b","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

        if echo "$test_result" | grep -q "choices\|content"; then
            echo "✓ Valid"
        else
            echo "✗ Invalid or rate limited"
        fi
    fi

    # Test Key 3 if provided
    if [ -n "$NVIDIA_API_KEY_PROJECT_3" ]; then
        echo -n "  Key 3 (PROJECT_3 - Nemotron 3 Ultra): "
        test_result=$(curl -s --max-time 15 \
            -H "Authorization: Bearer $NVIDIA_API_KEY_PROJECT_3" \
            -H "Content-Type: application/json" \
            -X POST https://integrate.api.nvidia.com/v1/chat/completions \
            -d '{"model":"nvidia/nemotron-3-ultra-550b-a55b","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

        if echo "$test_result" | grep -q "choices\|content"; then
            echo "✓ Valid"
        else
            echo "✗ Invalid or rate limited"
        fi
    fi

    # Test Key 4 if provided
    if [ -n "$NVIDIA_API_KEY_PROJECT_4" ]; then
        echo -n "  Key 4 (PROJECT_4 - Nemotron 3 Ultra): "
        test_result=$(curl -s --max-time 15 \
            -H "Authorization: Bearer $NVIDIA_API_KEY_PROJECT_4" \
            -H "Content-Type: application/json" \
            -X POST https://integrate.api.nvidia.com/v1/chat/completions \
            -d '{"model":"nvidia/nemotron-3-ultra-550b-a55b","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

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
# STEP 2: Model Mapping
# ============================================================
step2_model_mapping() {
    echo ""
    echo "============================================"
    echo "Step 2 of 4: Model Mapping"
    echo "All Claude Code models map to Nemotron 3 Ultra with different API keys for load isolation:"
    echo ""
    echo "  • claude-opus-5 (Default/Opus 1M) → Nemotron 3 Ultra (PROJECT_1)"
    echo "  • claude-sonnet-5 (Sonnet) → Nemotron 3 Ultra (PROJECT_2)"
    echo "  • claude-sonnet-5-1m (Sonnet 1M) → Nemotron 3 Ultra (PROJECT_3)"
    echo "  • claude-haiku-4-5 (Haiku) → Nemotron 3 Ultra (PROJECT_4)"
    echo ""
    echo "This provides 80 RPM combined (20 RPM per key) with load isolation."
    echo "============================================"

    # For now, use defaults. Advanced users can edit config.yaml later
    if yesno "Use this model mapping?\n\n(You can customize later by editing config.yaml)"; then
        return 0
    fi

    # Custom mapping - simplified for terminal
    echo ""
    echo "Custom mapping selected."
    echo "After installation, edit config.yaml to customize:"
    echo "  $REPO_DIR/config.yaml"
    echo ""
    echo "Each model entry has:"
    echo "  - model_name: claude-opus-5"
    echo "  - litellm_params.model: nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b"
    echo "  - litellm_params.api_key: os.environ/NVIDIA_API_KEY_PROJECT_1"

    return 0
}

# ============================================================
# STEP 3: Advanced Options
# ============================================================
step3_advanced() {
    echo ""
    echo "============================================"
    echo "Step 3 of 4: Advanced Options"
    echo "============================================"

    ENABLE_LAN=false
    ENABLE_TLS=false
    ENABLE_LOGGING=false
    CUSTOM_LIMITS=false
    CUSTOM_TIMEOUTS=false

    if yesno "Enable LAN Access (0.0.0.0:4000 + firewall)?"; then
        ENABLE_LAN=true
    fi

    if yesno "Enable TLS/SSL (HTTPS on port 4443)?"; then
        ENABLE_TLS=true
    fi

    if yesno "Enable request/response logging?"; then
        ENABLE_LOGGING=true
    fi

    if yesno "Custom nginx rate limits?"; then
        CUSTOM_LIMITS=true
        NGINX_RATE=$(inputbox "Nginx rate limit (req/s):" "16")
        NGINX_BURST=$(inputbox "Nginx burst limit:" "32")
    else
        NGINX_RATE=16
        NGINX_BURST=32
    fi

    if yesno "Custom timeouts?"; then
        CUSTOM_TIMEOUTS=true
        REQUEST_TIMEOUT=$(inputbox "Request timeout (seconds):" "3600")
    else
        REQUEST_TIMEOUT=3600
    fi

    # TLS domain input
    if [ "$ENABLE_TLS" = true ]; then
        TLS_DOMAIN=$(inputbox "Domain for TLS cert (e.g., myclaude.local):" "localhost")
        HTTPS_PORT=$(find_free_port 4443)
        if [ -z "$HTTPS_PORT" ]; then
            log_error "Could not find free port for HTTPS"
            exit 1
        fi
        log_info "Using HTTPS port: $HTTPS_PORT"
        if yesno "Also keep HTTP on port $NGINX_PORT? (Recommended for local access)"; then
            TLS_ENABLE_HTTP="true"
        else
            TLS_ENABLE_HTTP="false"
        fi
    else
        TLS_DOMAIN="localhost"
        TLS_ENABLE_HTTP="true"
        HTTPS_PORT=""
    fi

    return 0
}

# ============================================================
# STEP 4: Raw Payload Validation
# ============================================================
step4_payload() {
    echo ""
    echo "============================================"
    echo "Step 4 of 4: Raw Payload Validation"
    echo "You can customize the JSON payload sent to NVIDIA for each model."
    echo "Defaults are optimized for each model. Advanced users can edit after installation."
    echo "============================================"

    if yesno "View default payload for claude-opus-5?"; then
        cat <<'EOF'
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
        read -rp "Press Enter to continue..." _
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

        echo 75; echo "# Setting up Claude Code settings..."; sleep 1
        setup_claude_settings

        echo 80; echo "# Setting up aliases..."; sleep 1
        setup_bashrc

        echo 85; echo "# Installing wrapper..."; sleep 1
        setup_wrapper

        echo 90; echo "# Configuring LAN access..."; sleep 1
        setup_lan_hosting

        echo 95; echo "# Verification..."; sleep 1
        verify
    } | gauge "Installing MyClaude..."
}

# ============================================================
# ORIGINAL INSTALL FUNCTIONS (adapted for Terminal)
# ============================================================

write_env_file() {
    LOCAL_KEY="sk-local-$(openssl rand -hex 16 2>/dev/null || echo "proxykey$(date +%s)")"

    # Optional keys - fallback to PROJECT_1 if not provided
    NVIDIA_API_KEY_PROJECT_2="${NVIDIA_API_KEY_PROJECT_2:-$NVIDIA_API_KEY_PROJECT_1}"
    NVIDIA_API_KEY_PROJECT_3="${NVIDIA_API_KEY_PROJECT_3:-$NVIDIA_API_KEY_PROJECT_1}"
    NVIDIA_API_KEY_PROJECT_4="${NVIDIA_API_KEY_PROJECT_4:-$NVIDIA_API_KEY_PROJECT_1}"

    cat > "$REPO_DIR/.env" <<ENVEOF
# MyClaude Environment Configuration
# 4 API keys for Nemotron 3 Ultra (20 RPM each = ~80 RPM total combined)
# PROJECT_2-4 fall back to PROJECT_1 if not provided

NVIDIA_API_KEY_PROJECT_1="$NVIDIA_API_KEY_PROJECT_1"
NVIDIA_API_KEY_PROJECT_2="$NVIDIA_API_KEY_PROJECT_2"
NVIDIA_API_KEY_PROJECT_3="$NVIDIA_API_KEY_PROJECT_3"
NVIDIA_API_KEY_PROJECT_4="$NVIDIA_API_KEY_PROJECT_4"

LITELLM_MASTER_KEY="$LOCAL_KEY"
LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="true"
ENVEOF
}

setup_system_user() {
    # Ensure the service user exists (use existing user, don't create dedicated service user)
    if ! id "$SERVICE_USER" &>/dev/null; then
        # In --auto mode, create user if needed
        sudo useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    else
        # User exists, ensure it's a system user
        log_info "User $SERVICE_USER exists, using it for MyClaude service."
    fi
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true
}

setup_venv() {
    # Ensure the service user owns the repo directory
    sudo chown -R "$SERVICE_USER:$SERVICE_USER" "$REPO_DIR" 2>/dev/null || true
    sudo chmod 755 "$REPO_DIR" 2>/dev/null || true

    # Create venv as the service user (who now owns the repo)
    if [ ! -d "$VENV_DIR" ]; then
        sudo -u "$SERVICE_USER" python3 -m venv "$VENV_DIR"
    fi

    # Install packages as the service user
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" install --upgrade pip --quiet 2>/dev/null || true
    sudo -u "$SERVICE_USER" "$VENV_DIR/bin/pip" install 'litellm[proxy]' "fastapi<0.140.0" --quiet
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
        sudo sed -i '/http {/a\    limit_req_zone $binary_remote_addr zone=myclaude:10m rate=16r\/s;' /etc/nginx/nginx.conf
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
        echo "ERROR: Nginx config test failed. Check $NGINX_CONF"
        exit 1
    fi
}

setup_logrotate() {
    if [ -f "$REPO_DIR/logrotate-myclaude" ]; then
        local logrotate_conf
        logrotate_conf=$(mktemp)
        sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
            -e "s|__SERVICE_USER__|$SERVICE_USER|g" \
            "$REPO_DIR/logrotate-myclaude" > "$logrotate_conf"
        sudo cp "$logrotate_conf" /etc/logrotate.d/myclaude
        rm -f "$logrotate_conf"
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
        echo "ERROR: myclaude.service failed to start."
        echo "Check: journalctl -u $SERVICE_NAME -n 20"
        exit 1
    fi
}

setup_claude_code() {
    if command -v claude &>/dev/null; then
        return 0
    fi

    echo "Claude Code not found, installing..."

    if command -v npm &>/dev/null; then
        npm install -g @anthropic-ai/claude-code
    else
        echo "npm not found. Please install Node.js and run: npm install -g @anthropic-ai/claude-code"
        exit 1
    fi
}

setup_claude_settings() {
    log_info "Setting up ~/.claude/settings.json..."

    local CLAUDE_SETTINGS_DIR="$HOME/.claude"
    local CLAUDE_SETTINGS_FILE="$CLAUDE_SETTINGS_DIR/settings.json"

    mkdir -p "$CLAUDE_SETTINGS_DIR"

    # Check if settings.json already exists and prompt
    if [ -f "$CLAUDE_SETTINGS_FILE" ]; then
        if ! yesno "~/.claude/settings.json already exists. Overwrite with MyClaude optimized settings?"; then
            log_info "Keeping existing settings.json"
            return 0
        fi
    else
        log_info "Creating ~/.claude/settings.json with MyClaude optimized settings..."
    fi

    cat > "$CLAUDE_SETTINGS_FILE" <<'SETTINGSEOF'
{
  "autoCompactWindow": 1000000,
  "theme": "auto",
  "verbose": false,
  "permissions": {
    "bash": {
      "allow": [
        "git *",
        "gh *",
        "npm *",
        "npx *",
        "pip *",
        "pip3 *",
        "python *",
        "python3 *",
        "docker *",
        "docker-compose *",
        "kubectl *",
        "helm *",
        "terraform *",
        "ansible *",
        "make *",
        "cmake *",
        "cargo *",
        "go *",
        "mvn *",
        "gradle *",
        "systemctl *",
        "service *",
        "journalctl *",
        "nginx *",
        "ufw *",
        "firewall-cmd *",
        "iptables *",
        "ss *",
        "netstat *",
        "lsof *",
        "ps *",
        "top *",
        "htop *",
        "free *",
        "df *",
        "du *",
        "ls *",
        "find *",
        "grep *",
        "rg *",
        "awk *",
        "sed *",
        "cat *",
        "head *",
        "tail *",
        "less *",
        "more *",
        "vim *",
        "nano *",
        "code *",
        "chmod *",
        "chown *",
        "mkdir *",
        "rm *",
        "cp *",
        "mv *",
        "ln *",
        "tar *",
        "gzip *",
        "gunzip *",
        "unzip *",
        "curl *",
        "wget *",
        "ssh *",
        "scp *",
        "rsync *",
        "sudo *",
        "apt *",
        "apt-get *",
        "dnf *",
        "yum *",
        "pacman *",
        "zypper *",
        "snap *",
        "flatpak *",
        "brew *",
        "npm *",
        "yarn *",
        "pnpm *",
        "bun *",
        "deno *",
        "nvm *",
        "fnm *",
        "pyenv *",
        "rbenv *",
        "rustup *",
        "sdkman *",
        "asdf *"
      ],
      "deny": []
    }
  },
  "autoCompact": true,
  "autoScroll": true,
  "mcpServers": {
    "github": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-github"
      ],
      "env": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}"
      }
    },
    "filesystem": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "${HOME}"
      ]
    },
    "fetch": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-fetch"
      ]
    },
    "brave-search": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-brave-search"
      ],
      "env": {
        "BRAVE_API_KEY": "${BRAVE_API_KEY}"
      }
    },
    "postgres": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-postgres"
      ],
      "env": {
        "POSTGRES_CONNECTION_STRING": "${POSTGRES_URL}"
      }
    },
    "sqlite": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-sqlite",
        "--db-path",
        "${HOME}/data.db"
      ]
    },
    "redis": {
      "command": "npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-redis"
      ],
      "env": {
        "REDIS_URL": "${REDIS_URL}"
      }
    }
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[PRE] Running: $TOOL_INPUT'"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "echo '[POST] Completed: $TOOL_INPUT'"
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "echo 'Session ended at $(date)'"
          }
        ]
      }
    ]
  },
  "model": "opus[1m]",
  "maxTokens": 8192,
  "temperature": 0.1,
  "env": {
    "CLAUDE_CODE_AUTO_COMPACT": "true",
    "CLAUDE_CODE_MAX_THINKING_TOKENS": "32000",
    "CLAUDE_CODE_ENABLE_THINKING": "true",
    "CLAUDE_CODE_BYPASS_PERMISSIONS": "false"
  },
  "agentSettings": {
    "defaultAgent": "general-purpose",
    "availableAgents": [
      "general-purpose",
      "code-reviewer",
      "security-auditor",
      "performance-engineer",
      "devops-engineer",
      "database-engineer",
      "frontend-engineer",
      "backend-engineer",
      "ml-engineer",
      "api-designer",
      "test-engineer",
      "documentation-writer"
    ]
  },
  "workspace": {
    "root": "${HOME}",
    "include": [
      "**/*.py",
      "**/*.js",
      "**/*.ts",
      "**/*.json",
      "**/*.yaml",
      "**/*.yml",
      "**/*.md",
      "**/*.sh",
      "**/*.dockerfile",
      "**/Dockerfile*",
      "**/*.tf",
      "**/*.go",
      "**/*.rs",
      "**/*.java",
      "**/*.kt",
      "**/*.cs",
      "**/*.cpp",
      "**/*.c",
      "**/*.h",
      "**/*.hpp"
    ],
    "exclude": [
      "node_modules/**",
      ".git/**",
      "venv/**",
      "__pycache__/**",
      "*.log",
      "*.tmp",
      "dist/**",
      "build/**",
      ".next/**",
      "target/**",
      "*.min.js",
      "*.min.css"
    ]
  },
  "telemetry": {
    "enabled": false
  },
  "notifications": {
    "enabled": true,
    "sound": false
  },
  "useCustomApiKey": false
}
SETTINGSEOF

    log_success "Created ~/.claude/settings.json with MyClaude optimized configuration"
    log_info "Includes: MCP servers (GitHub, Filesystem, Fetch, Brave Search, Postgres, SQLite, Redis)"
    log_info "Includes: Permissive bash permissions for development tools"
    log_info "Includes: Auto-compact, thinking enabled, Opus 1M model"
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
    # Use the comprehensive myclaude.sh wrapper from the repo
    sudo cp "$REPO_DIR/myclaude.sh" /usr/local/bin/myclaude
    sudo chmod +x /usr/local/bin/myclaude
}

setup_tls() {
    if [ "$ENABLE_TLS" = true ]; then
        log_info "Setting up TLS/SSL..."
        # Use the setup-tls.sh script
        if [ -f "$REPO_DIR/setup-tls.sh" ]; then
            bash "$REPO_DIR/setup-tls.sh" generate "$TLS_DOMAIN" "$TLS_ENABLE_HTTP"
        else
            log_error "WARNING: setup-tls.sh not found. TLS not configured."
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
        echo "ERROR: Nginx NOT on port 4000"
        exit 1
    fi
    if ! ss -tlnp 2>/dev/null | grep -q ':4001 '; then
        echo "ERROR: LiteLLM NOT on port 4001"
        exit 1
    fi

    local test_result
    test_result=$(curl -s --max-time 15 \
        -H "Authorization: Bearer sk-local-proxy-key" \
        -H "Content-Type: application/json" \
        -X POST http://localhost:4000/v1/chat/completions \
        -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

    if ! echo "$test_result" | grep -q "choices\|content"; then
        echo "WARNING: Proxy test returned unexpected result:"
        echo "$test_result"
    fi

    # Test HTTPS if TLS enabled
    if [ "$ENABLE_TLS" = true ]; then
        if ! ss -tlnp 2>/dev/null | grep -q ':4443 '; then
            echo "WARNING: HTTPS NOT on port 4443"
        else
            test_result=$(curl -k -s --max-time 15 \
                -H "Authorization: Bearer sk-local-proxy-key" \
                -H "Content-Type: application/json" \
                -X POST https://localhost:4443/v1/chat/completions \
                -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

            if ! echo "$test_result" | grep -q "choices\|content"; then
                echo "WARNING: HTTPS proxy test returned unexpected result:"
                echo "$test_result"
            fi
        fi
    fi
}

# ============================================================
# MAIN FLOW
# ============================================================
main() {
    cd "$REPO_DIR"

    # Welcome screen
    msgbox "Welcome to MyClaude Installer

This will set up:
• nginx reverse proxy (port 4000)
• LiteLLM proxy (port 4001)
• NVIDIA NIM model routing
• systemd service
• myclaude command wrapper

Continue?"

    # Step 1: API Keys
    step1_api_keys

    # Step 2: Model Mapping
    step2_model_mapping

    # Step 3: Advanced Options
    step3_advanced

    # Step 4: Payload Validation
    step4_payload

    # Confirm installation
    if ! yesno "Ready to install MyClaude?

This will:
• Install system packages (nginx, python3-venv)
• Set up Python venv + LiteLLM
• Configure nginx + systemd
• Install myclaude wrapper command

Proceed?"; then
        echo "Installation cancelled."
        exit 0
    fi

    # Run installation
    run_installation

    # Success
    echo ""
    echo "Installation Complete!"
    echo ""
    echo "Quick start:"
    echo "  myclaude              # launch Claude Code"
    echo "  myclaude --help       # pass args to Claude Code"
    echo ""
    echo "Service management:"
    echo "  sudo systemctl status myclaude"
    echo "  sudo systemctl restart myclaude"
    echo "  journalctl -u myclaude -f"
    echo ""
    echo "Convenience aliases (run 'source ~/.bashrc'):"
    echo "  myclaude-status  myclaude-logs  myclaude-start  myclaude-stop"
}

# Handle --auto mode for non-interactive
if [[ "${1:-}" == "--auto" ]]; then
    # Use environment variables (all Nemotron 3 Ultra with 4 project keys)
    NVIDIA_API_KEY_PROJECT_1="${NVIDIA_API_KEY_PROJECT_1:-}"
    NVIDIA_API_KEY_PROJECT_2="${NVIDIA_API_KEY_PROJECT_2:-}"
    NVIDIA_API_KEY_PROJECT_3="${NVIDIA_API_KEY_PROJECT_3:-}"
    NVIDIA_API_KEY_PROJECT_4="${NVIDIA_API_KEY_PROJECT_4:-}"
    ENABLE_LAN="${ENABLE_LAN:-false}"
    ENABLE_TLS="${ENABLE_TLS:-false}"
    TLS_DOMAIN="${TLS_DOMAIN:-localhost}"
    TLS_ENABLE_HTTP="${TLS_ENABLE_HTTP:-true}"
    NGINX_RATE="${NGINX_RATE:-16}"
    NGINX_BURST="${NGINX_BURST:-32}"
    REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-3600}"

    if [ -z "$NVIDIA_API_KEY_PROJECT_1" ]; then
        echo "ERROR: NVIDIA_API_KEY_PROJECT_1 required for --auto mode"
        exit 1
    fi

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
    setup_claude_settings
    setup_bashrc
    setup_wrapper
    setup_lan_hosting
    verify

    echo "Auto installation complete!"
    echo "Run 'myclaude' to start Claude Code"
    exit 0
fi

# Run main
main "$@"