#!/bin/bash
# MyClaude Model Test Script
# Tests all 4 configured models via the proxy

set -euo pipefail

PROXY_URL="http://localhost:4000"
API_KEY="sk-local-proxy-key"
TIMEOUT=30

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Models to test (model_name:expected_backend)
declare -A MODELS=(
    ["claude-opus-5"]="nvidia/nemotron-3-ultra-550b-a55b"
    ["claude-sonnet-5"]="nvidia/nemotron-3-super-120b-a12b"
    ["claude-sonnet-5-1m"]="minimaxai/minimax-m3"
    ["claude-haiku-4-5"]="stepfun-ai/step-3.7-flash"
)

# Test a single model
test_model() {
    local model="$1"
    local expected_backend="${MODELS[$model]:-unknown}"

    echo -n "Testing $model ($expected_backend)... "

    local response
    response=$(curl -s --max-time "$TIMEOUT" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        -X POST "$PROXY_URL/v1/chat/completions" \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word\"}],\"max_tokens\":20}" 2>&1) || true

    # Check for valid response
    if echo "$response" | grep -q '"choices"'; then
        local content
        content=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    choices = data.get('choices', [])
    if choices:
        msg = choices[0].get('message', {})
        content = msg.get('content', '')
        if isinstance(content, list):
            # Handle Anthropic format
            for c in content:
                if c.get('type') == 'text':
                    print(c.get('text', '')[:50])
                    break
        else:
            print(content[:50])
except:
    pass
" 2>/dev/null)
        log_success "$model - Response: ${content:-'(empty)'}"
        return 0
    elif echo "$response" | grep -q '"error"'; then
        local error_msg
        error_msg=$(echo "$response" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    err = data.get('error', {})
    print(err.get('message', str(err))[:80])
except:
    pass
" 2>/dev/null)
        log_fail "$model - Error: ${error_msg:-'$response'}"
        return 1
    else
        log_fail "$model - Unexpected response: ${response:0:80}"
        return 1
    fi
}

# Test health endpoint
test_health() {
    echo -n "Testing nginx health endpoint... "
    if curl -s --max-time 5 "$PROXY_URL/health" | grep -q "healthy"; then
        log_success "nginx /health OK"
        return 0
    else
        log_fail "nginx /health failed"
        return 1
    fi
}

# Test LiteLLM health (if available)
test_litellm_health() {
    echo -n "Testing LiteLLM health endpoint... "
    if curl -s --max-time 5 "http://localhost:4001/health" | grep -q "healthy"; then
        log_success "LiteLLM /health OK"
        return 0
    else
        log_warn "LiteLLM /health not available (optional)"
        return 0
    fi
}

# Main
main() {
    log_info "Testing MyClaude proxy at $PROXY_URL"
    log_info "Testing ${#MODELS[@]} models..."
    echo ""

    local passed=0
    local failed=0

    # Health checks
    test_health || true
    test_litellm_health || true
    echo ""

    # Model tests
    for model in "${!MODELS[@]}"; do
        if test_model "$model"; then
            ((passed++))
        else
            ((failed++))
        fi
    done

    echo ""
    log_info "Results: $passed passed, $failed failed"

    if [ $failed -eq 0 ]; then
        log_success "All models working!"
        exit 0
    else
        log_fail "Some models failed"
        exit 1
    fi
}

main "$@"