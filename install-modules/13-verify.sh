#!/bin/bash
# Module: 13-verify
# Verify installation

run_13_verify() {
    verify_installation
}

verify_installation() {
    log_info "Verifying installation..."

    # Check nginx on port 4000
    if ! ss -tlnp 2>/dev/null | grep -q ':4000 '; then
        log_error "Nginx NOT listening on port 4000"
        exit 1
    fi
    log_success "Nginx listening on port 4000"

    # Check LiteLLM on port 4001
    if ! ss -tlnp 2>/dev/null | grep -q ':4001 '; then
        log_error "LiteLLM NOT listening on port 4001"
        exit 1
    fi
    log_success "LiteLLM listening on port 4001"

    # Test HTTP health endpoint
    local test_result
    test_result=$(curl -s --max-time 15 \
        -H "Authorization: Bearer sk-local-proxy-key" \
        -H "Content-Type: application/json" \
        -X POST http://localhost:4000/v1/chat/completions \
        -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

    if echo "$test_result" | grep -q "choices\|content"; then
        log_success "Proxy test passed (HTTP)"
    else
        log_warn "Proxy test returned unexpected result:"
        echo "$test_result" | head -5
    fi

    # Test HTTPS if TLS enabled
    if [ "$ENABLE_TLS" = true ]; then
        if ! ss -tlnp 2>/dev/null | grep -q ':4443 '; then
            log_warn "HTTPS NOT listening on port 4443"
        else
            test_result=$(curl -k -s --max-time 15 \
                -H "Authorization: Bearer sk-local-proxy-key" \
                -H "Content-Type: application/json" \
                -X POST https://localhost:4443/v1/chat/completions \
                -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"test"}],"max_tokens":5}' 2>&1) || true

            if echo "$test_result" | grep -q "choices\|content"; then
                log_success "Proxy test passed (HTTPS)"
            else
                log_warn "HTTPS proxy test returned unexpected result:"
                echo "$test_result" | head -5
            fi
        fi
    fi

    # Check memory usage
    log_info "Current memory usage:"
    ps aux | awk '/[l]itellm|[n]ginx: worker/ {sum+=$6; print $0} END {print "Total RSS: " sum/1024 " MB"}'

    # Check on-demand config
    if grep -q "MYCLAUDE_IDLE_TIMEOUT" "$REPO_DIR/.env"; then
        local timeout
        timeout=$(grep "MYCLAUDE_IDLE_TIMEOUT" "$REPO_DIR/.env" | cut -d= -f2)
        log_success "On-demand mode enabled (idle timeout: ${timeout}s)"
    fi

    # Check nginx worker_processes
    if grep -q "worker_processes 1;" /etc/nginx/nginx.conf; then
        log_success "Nginx optimized for on-demand (worker_processes=1)"
    fi

    log_success "Verification complete"
}