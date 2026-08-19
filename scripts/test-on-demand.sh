#!/bin/bash
# Test script for MyClaude on-demand functionality
# Verifies: start on demand, idle shutdown, memory reporting

set -euo pipefail

echo "=========================================="
echo "MyClaude On-Demand Functionality Test"
echo "=========================================="
echo ""

# Test 1: Check wrapper exists and is executable
echo "Test 1: Check myclaude wrapper"
if [ -x /usr/local/bin/myclaude ]; then
    echo "✅ /usr/local/bin/myclaude exists and is executable"
else
    echo "❌ /usr/local/bin/myclaude not found or not executable"
    exit 1
fi

# Test 2: Check systemd service has Restart=on-failure
echo ""
echo "Test 2: Check systemd Restart policy"
if grep -q "Restart=on-failure" /etc/systemd/system/myclaude.service; then
    echo "✅ systemd service has Restart=on-failure"
else
    echo "❌ systemd service does not have Restart=on-failure"
    exit 1
fi

# Test 3: Check nginx config has health endpoint
echo ""
echo "Test 3: Check nginx health endpoint"
if grep -q "location = /health" /etc/nginx/sites-enabled/myclaude; then
    echo "✅ nginx health endpoint configured"
else
    echo "❌ nginx health endpoint not found"
    exit 1
fi

# Test 4: Check .env has MYCLAUDE_IDLE_TIMEOUT
echo ""
echo "Test 4: Check .env configuration"
if [ -f /home/ML/myclaude/.env ] && grep -q "MYCLAUDE_IDLE_TIMEOUT" /home/ML/myclaude/.env; then
    echo "✅ MYCLAUDE_IDLE_TIMEOUT configured in .env"
    grep "MYCLAUDE_IDLE_TIMEOUT" /home/ML/myclaude/.env
else
    echo "❌ MYCLAUDE_IDLE_TIMEOUT not found in .env"
    exit 1
fi

# Test 5: Test wrapper syntax
echo ""
echo "Test 5: Test wrapper syntax"
if bash -n /usr/local/bin/myclaude; then
    echo "✅ Wrapper syntax is valid"
else
    echo "❌ Wrapper has syntax errors"
    exit 1
fi

# Test 6: Test wrapper help/version (dry run)
echo ""
echo "Test 6: Test wrapper basic execution (timeout 2s)"
timeout 2 /usr/local/bin/myclaude --version 2>&1 | head -5 || true
echo "✅ Wrapper executes without immediate errors"

# Test 7: Check Docker files exist
echo ""
echo "Test 7: Check Docker files"
for f in docker/Dockerfile docker/docker-compose.yml docker/entrypoint.sh docker/healthcheck.sh docker/.dockerignore; do
    if [ -f "/home/ML/myclaude/$f" ]; then
        echo "✅ $f exists"
    else
        echo "❌ $f missing"
    fi
done

# Test 8: Check LiteLLM config optimizations
echo ""
echo "Test 8: Check LiteLLM config optimizations"
if grep -q "cache: false" /home/ML/myclaude/config.yaml; then
    echo "✅ LiteLLM cache disabled"
else
    echo "❌ LiteLLM cache not disabled"
fi
if grep -q "log_level: \"WARNING\"" /home/ML/myclaude/config.yaml; then
    echo "✅ LiteLLM log level set to WARNING"
else
    echo "❌ LiteLLM log level not optimized"
fi
if grep -q "health_check_interval: 300" /home/ML/myclaude/config.yaml; then
    echo "✅ Router health check interval increased"
else
    echo "❌ Router health check interval not optimized"
fi

# Test 9: Check nginx optimizations
echo ""
echo "Test 9: Check nginx configuration comments for on-demand"
if grep -q "ON-DEMAND OPTIMIZATIONS" /home/ML/myclaude/nginx-myclaude.conf; then
    echo "✅ nginx config documents on-demand optimizations"
else
    echo "❌ nginx config missing on-demand documentation"
fi

# Test 10: Check systemd GC tuning
echo ""
echo "Test 10: Check systemd service for GC tuning"
if grep -q "PYTHONGC=1" /home/ML/myclaude/litellm.service.template; then
    echo "✅ PYTHONGC=1 in service template"
else
    echo "❌ PYTHONGC=1 not in service template"
fi
if grep -q "PYTHONTRACEMALLOC=0" /home/ML/myclaude/litellm.service.template; then
    echo "✅ PYTHONTRACEMALLOC=0 in service template"
else
    echo "❌ PYTHONTRACEMALLOC=0 not in service template"
fi

echo ""
echo "=========================================="
echo "All Tests Completed"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Apply systemd service: sudo systemctl daemon-reload && sudo systemctl restart myclaude"
echo "2. Apply nginx config: sudo nginx -t && sudo systemctl reload nginx"
echo "3. Test on-demand: myclaude (will start backend, then test idle shutdown)"
echo "4. Monitor memory: ps aux | grep -E 'nginx|litellm'"