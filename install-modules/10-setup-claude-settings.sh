#!/bin/bash
# Module 10: Configure Claude Code settings
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Configuring Claude Code settings..."

CLAUDE_CONFIG_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR"

# Write settings.json for proxy configuration
cat > "$CLAUDE_CONFIG_DIR/settings.json" <<EOF
{
  "apiEndpoint": "http://localhost:4000",
  "dangerouslySkipPermissions": false
}
EOF

log_info "Claude Code settings configured at $CLAUDE_CONFIG_DIR/settings.json"