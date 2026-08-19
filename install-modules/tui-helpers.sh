#!/bin/bash
# Module: tui-helpers
# TUI helper functions for interactive mode

# Check TUI tool
TUI_TOOL=""
if command -v whiptail &>/dev/null; then
    TUI_TOOL="whiptail"
elif command -v dialog &>/dev/null; then
    TUI_TOOL="dialog"
fi

# TUI wrapper functions
ui_msgbox() {
    local msg="$1"
    local height="${2:-12}"
    local width="${3:-70}"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --msgbox "$msg" "$height" "$width"
    else
        dialog --title "MyClaude Installer" --msgbox "$msg" "$height" "$width"
    fi
}

ui_inputbox() {
    local prompt="$1"
    local default="$2"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --inputbox "$prompt" 12 70 "$default" 3>&1 1>&2 2>&3
    else
        dialog --title "MyClaude Installer" --inputbox "$prompt" 12 70 "$default" 3>&1 1>&2 2>&3
    fi
}

ui_passwordbox() {
    local prompt="$1"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --passwordbox "$prompt" 12 70 3>&1 1>&2 2>&3
    else
        dialog --title "MyClaude Installer" --passwordbox "$prompt" 12 70 3>&1 1>&2 2>&3
    fi
}

ui_yesno() {
    local prompt="$1"
    if [ "$TUI_TOOL" = "whiptail" ]; then
        whiptail --title "MyClaude Installer" --yesno "$prompt" 12 70
    else
        dialog --title "MyClaude Installer" --yesno "$prompt" 12 70
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

# Step 1: API Keys
step1_api_keys() {
    ui_msgbox "Step 1 of 3: API Keys\n\nYou need at least one NVIDIA NIM API key.\nGet free keys at: https://build.nvidia.com\n\nAll models use Nemotron 3 Ultra. You can configure up to 4 keys for load isolation (80 RPM combined)."

    # Key 1 - Required
    while true; do
        NVIDIA_API_KEY_PROJECT_1=$(ui_passwordbox "Key 1: Primary NVIDIA (Required)\n\nEnter your NVIDIA NIM API key for Nemotron 3 Ultra (nvapi-...):" "")
        if [ -n "$NVIDIA_API_KEY_PROJECT_1" ]; then
            break
        fi
        ui_msgbox "API key cannot be empty. Please try again."
    done

    # Key 2 - Optional
    NVIDIA_API_KEY_PROJECT_2=$(ui_passwordbox "Key 2: Nemotron Ultra - Project 2 (Optional)\n\nEnter API key for load isolation (press Enter to skip, falls back to Key 1):" "")

    # Key 3 - Optional
    NVIDIA_API_KEY_PROJECT_3=$(ui_passwordbox "Key 3: Nemotron Ultra - Project 3 (Optional)\n\nEnter API key for load isolation (press Enter to skip, falls back to Key 1):" "")

    # Key 4 - Optional
    NVIDIA_API_KEY_PROJECT_4=$(ui_passwordbox "Key 4: Nemotron Ultra - Project 4 (Optional)\n\nEnter API key for load isolation (press Enter to skip, falls back to Key 1):" "")

    # Validate keys
    if ui_yesno "Test API keys now? (Recommended)"; then
        test_keys
    fi

    export NVIDIA_API_KEY_PROJECT_1 NVIDIA_API_KEY_PROJECT_2 NVIDIA_API_KEY_PROJECT_3 NVIDIA_API_KEY_PROJECT_4
    return 0
}

test_keys() {
    echo "Testing API keys (all Nemotron 3 Ultra)..."

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

# Step 2: Advanced Options
step3_advanced() {
    ui_msgbox "Step 2 of 3: Advanced Options"

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
        NGINX_RATE=$(ui_inputbox "Nginx rate limit (req/s):" "50")
        NGINX_BURST=$(ui_inputbox "Nginx burst limit:" "100")
    else
        NGINX_RATE=50
        NGINX_BURST=100
    fi

    if [ "$CUSTOM_TIMEOUTS" = true ]; then
        REQUEST_TIMEOUT=$(ui_inputbox "Request timeout (seconds):" "3600")
    else
        REQUEST_TIMEOUT=3600
    fi

    # TLS domain input
    if [ "$ENABLE_TLS" = true ]; then
        TLS_DOMAIN=$(ui_inputbox "Domain for TLS cert (e.g., myclaude.local):" "localhost")
        if ui_yesno "Also keep HTTP on port 4000? (Recommended for local access)"; then
            TLS_ENABLE_HTTP="true"
        else
            TLS_ENABLE_HTTP="false"
        fi
    else
        TLS_DOMAIN="localhost"
        TLS_ENABLE_HTTP="true"
    fi

    export ENABLE_LAN ENABLE_TLS TLS_DOMAIN TLS_ENABLE_HTTP NGINX_RATE NGINX_BURST REQUEST_TIMEOUT ENABLE_LOGGING
    return 0
}