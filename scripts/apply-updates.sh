#!/bin/bash
# Apply all on-demand updates to the running system
# Run with: sudo bash /home/ML/myclaude/scripts/apply-updates.sh

set -euo pipefail

echo "=========================================="
echo "Applying MyClaude On-Demand Updates"
echo "=========================================="
echo ""

# 1. Update systemd service
echo "1. Updating systemd service..."
cp /home/ML/myclaude/litellm.service.template /etc/systemd/system/myclaude.service
# Fix template variables for current installation
sed -i 's|__REPO_DIR__|/home/ML/myclaude|g' /etc/systemd/system/myclaude.service
sed -i 's|__VENV_DIR__|/home/ML/myclaude/venv|g' /etc/systemd/system/myclaude.service
sed -i 's|__SERVICE_USER__|ML|g' /etc/systemd/system/myclaude.service
sed -i 's|__PORT__|4001|g' /etc/systemd/system/myclaude.service
systemctl daemon-reload
echo "   ✅ systemd service updated and reloaded"

# 2. Update nginx configuration
echo "2. Updating nginx configuration..."
cp /home/ML/myclaude/nginx-myclaude.conf /etc/nginx/sites-enabled/myclaude
# Apply on-demand optimizations if MYCLAUDE_IDLE_TIMEOUT > 0
if [ -f /home/ML/myclaude/.env ] && grep -q "MYCLAUDE_IDLE_TIMEOUT" /home/ML/myclaude/.env; then
    idle_timeout=$(grep "MYCLAUDE_IDLE_TIMEOUT" /home/ML/myclaude/.env | cut -d= -f2)
    if [ "$idle_timeout" -gt 0 ] 2>/dev/null; then
        echo "   Applying on-demand nginx optimizations..."
        sed -i 's/^worker_processes auto;/worker_processes 1;/' /etc/nginx/nginx.conf
        if ! grep -q "client_body_buffer_size 64k;" /etc/nginx/nginx.conf 2>/dev/null; then
            sed -i '/http {/a\    client_body_buffer_size 64k;\n    client_header_buffer_size 512;\n    keepalive_timeout 30s;' /etc/nginx/nginx.conf
        fi
    fi
fi
nginx -t && systemctl reload nginx
echo "   ✅ nginx configuration updated and reloaded"

# 3. Update myclaude wrapper (already in place at /usr/local/bin/myclaude)
echo "3. Verifying myclaude wrapper..."
if [ -x /usr/local/bin/myclaude ]; then
    echo "   ✅ Wrapper already installed"
else
    cp /home/ML/myclaude/myclaude.sh /usr/local/bin/myclaude
    chmod +x /usr/local/bin/myclaude
    echo "   ✅ Wrapper installed"
fi

# 4. Restart services
echo "4. Restarting services..."
systemctl restart myclaude
sleep 3
if systemctl is-active --quiet myclaude; then
    echo "   ✅ myclaude service restarted successfully"
else
    echo "   ❌ myclaude service failed to start"
    journalctl -u myclaude -n 20
    exit 1
fi

# 5. Verify health endpoint
echo "5. Verifying health endpoint..."
sleep 2
if curl -s --max-time 5 -f "http://localhost:4000/health" >/dev/null 2>&1; then
    echo "   ✅ Health endpoint responding"
else
    echo "   ⚠️  Health endpoint not yet responding (may need more time)"
fi

# 6. Show memory usage
echo "6. Current memory usage:"
ps aux | awk '/[l]itellm|[n]ginx: worker/ {sum+=$6; print $0} END {print "Total RSS: " sum/1024 " MB"}'

echo ""
echo "=========================================="
echo "All Updates Applied Successfully!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  - Test on-demand: myclaude"
echo "  - Monitor idle shutdown: watch -n 5 'ps aux | grep -E nginx|litellm'"
echo "  - Check logs: journalctl -u myclaude -f"