#!/bin/bash
# Fix all issues - run with: sudo bash scripts/fix-all.sh (from repo root)

set -euo pipefail

# Determine repo directory
if [[ "${BASH_SOURCE[0]}" == /* ]]; then
    REPO_DIR="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
else
    REPO_DIR="$(pwd)"
fi

# Source detect-os to get variables
source "$REPO_DIR/install-modules/01-detect-os.sh"

echo "=========================================="
echo "Fixing MyClaude Issues"
echo "=========================================="

# 1. Fix nginx.conf - set worker_processes 1 and add buffer optimizations
echo "1. Fixing nginx.conf..."
sed -i 's/worker_processes auto;/worker_processes 1;/' /etc/nginx/nginx.conf

# Add buffer optimizations to http block if not present
if ! grep -q "client_body_buffer_size 64k;" /etc/nginx/nginx.conf; then
    sed -i '/http {/a\    client_body_buffer_size 64k;\n    client_header_buffer_size 512;\n    keepalive_timeout 30s;\n    worker_connections 1024;' /etc/nginx/nginx.conf
fi

# 2. Fix nginx site config - copy from template
echo "2. Fixing nginx site config..."
sudo cp "$REPO_DIR/nginx-myclaude.conf" /etc/nginx/sites-enabled/myclaude

# 3. Test and reload nginx
echo "3. Testing nginx config..."
nginx -t
systemctl reload nginx

# 4. Kill duplicate litellm process on port 4000
echo "4. Killing duplicate litellm on port 4000..."
pkill -f "litellm.*port 4000" 2>/dev/null || true

# 5. Update systemd service with correct template
echo "5. Updating systemd service..."
local svc
svc=$(mktemp)
sed -e "s|__REPO_DIR__|$REPO_DIR|g" \
    -e "s|__VENV_DIR__|$REPO_DIR/venv|g" \
    -e "s|__SERVICE_USER__|$INSTALL_USER|g" \
    -e "s|__PORT__|4001|g" \
    "$REPO_DIR/litellm.service.template" > "$svc"
sudo cp "$svc" /etc/systemd/system/myclaude.service
rm -f "$svc"
systemctl daemon-reload

# 6. Restart myclaude service
echo "6. Restarting myclaude service..."
systemctl restart myclaude
sleep 3

# 7. Verify
echo "7. Verifying..."
sleep 2
curl -s http://localhost:4000/health
echo ""
curl -s http://localhost:4000/health/litellm
echo ""

# 8. Show memory
echo "8. Memory usage:"
ps aux | awk '/[l]itellm|[n]ginx: worker/ {sum+=$6; print $0} END {print "Total RSS: " sum/1024 " MB"}'

echo ""
echo "=========================================="
echo "Fix Complete!"
echo "=========================================="