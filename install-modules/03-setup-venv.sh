#!/bin/bash
# Module 03: Setup Python virtual environment
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Setting up Python virtual environment..."

VENV_DIR="$REPO_DIR/venv"

# Create venv
python3 -m venv "$VENV_DIR"

# Upgrade pip and install packages
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install 'litellm[proxy]' "fastapi<0.140.0"

# Verify
if [[ ! -f "$VENV_DIR/bin/litellm" ]]; then
    log_error "litellm not installed in venv"
    exit 1
fi

log_info "Virtual environment ready at $VENV_DIR"
export VENV_DIR
