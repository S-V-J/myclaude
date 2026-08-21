#!/bin/bash
# Module 04: Write .env file with API keys
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Writing .env file..."

# Generate master key
LOCAL_KEY="sk-local-$(openssl rand -hex 16)"

# Check for required API key
: ${NVIDIA_API_KEY_PROJECT_1:?"NVIDIA_API_KEY_PROJECT_1 not set"}

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

chmod 600 "$REPO_DIR/.env"
log_info ".env written with master key: $LOCAL_KEY"
