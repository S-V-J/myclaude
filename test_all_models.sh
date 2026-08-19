#!/bin/bash
# Test ALL 4 models with EXACT raw payloads from config.yaml
# All models use Nemotron 3 Ultra with different API keys for load isolation
# Run this script: bash test_all_models.sh

set -euo pipefail

# Load API keys
source /home/ML/myclaude/.env

# Output file
OUTPUT="/tmp/model_test_results_$(date +%s).txt"
echo "Testing all 4 models with exact config.yaml payloads..." | tee "$OUTPUT"
echo "Timestamp: $(date)" | tee -a "$OUTPUT"
echo "============================================================" | tee -a "$OUTPUT"
echo "Configuration: All models use Nemotron 3 Ultra with different API keys" | tee -a "$OUTPUT"
echo "============================================================" | tee -a "$OUTPUT"

test_model() {
    local name="$1"
    local key="$2"
    local project="$3"
    local max_tokens="$4"

    echo "" | tee -a "$OUTPUT"
    echo "============================================================" | tee -a "$OUTPUT"
    echo "TESTING: $name" | tee -a "$OUTPUT"
    echo "Project: $project" | tee -a "$OUTPUT"
    echo "Model: nvidia/nemotron-3-ultra-550b-a55b" | tee -a "$OUTPUT"
    echo "Max tokens: $max_tokens" | tee -a "$OUTPUT"
    echo "============================================================" | tee -a "$OUTPUT"

    if [ -z "$key" ]; then
        echo "SKIPPED: Key not set" | tee -a "$OUTPUT"
        return
    fi

    # Build payload
    PAYLOAD=$(cat <<EOF
{
    "model": "nvidia/nemotron-3-ultra-550b-a55b",
    "messages": [{"role": "user", "content": "You are a senior software engineer. Write a complete Python async HTTP client with retry logic, exponential backoff, circuit breaker, and connection pooling. Include type hints, docstrings, and unit tests. Output only the code."}],
    "temperature": 1.0,
    "top_p": 0.95,
    "max_tokens": $max_tokens,
    "seed": 42,
    "stream": false,
    "extra_body": {
        "chat_template_kwargs": {"enable_thinking": true},
        "reasoning_budget": 16384
    }
}
EOF
)

    START=$(date +%s)
    RESPONSE=$(curl -s --max-time 120 \
        -H "Authorization: Bearer $key" \
        -H "Content-Type: application/json" \
        -X POST https://integrate.api.nvidia.com/v1/chat/completions \
        -d "$PAYLOAD" 2>&1)
    END=$(date +%s)
    DURATION=$((END - START))

    echo "Duration: ${DURATION}s" | tee -a "$OUTPUT"

    # Parse response
    if echo "$RESPONSE" | grep -q '"choices"'; then
        CONTENT=$(echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
choices = data.get('choices', [])
if choices:
    msg = choices[0].get('message', {})
    content = msg.get('content', '')
    if isinstance(content, list):
        for c in content:
            if c.get('type') == 'text':
                print(c.get('text', '')[:2000])
                break
    else:
        print(content[:2000])
")
        echo "✅ SUCCESS" | tee -a "$OUTPUT"
        echo "Response length: ${#CONTENT} chars" | tee -a "$OUTPUT"
        echo "Preview: ${CONTENT:0:200}..." | tee -a "$OUTPUT"

        USAGE=$(echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
usage = data.get('usage', {})
print(f'Prompt: {usage.get(\"prompt_tokens\", \"N/A\")}, Completion: {usage.get(\"completion_tokens\", \"N/A\")}, Total: {usage.get(\"total_tokens\", \"N/A\")}')
")
        echo "Token Usage: $USAGE" | tee -a "$OUTPUT"

    elif echo "$RESPONSE" | grep -q '"error"'; then
        ERROR=$(echo "$RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
err = data.get('error', {})
print(err.get('message', str(err))[:300])
")
        echo "❌ ERROR: $ERROR" | tee -a "$OUTPUT"

        # Check for 429
        if echo "$RESPONSE" | grep -q '"code": 429'; then
            echo "⚠️  RATE LIMITED (429) - NVIDIA free tier limit hit" | tee -a "$OUTPUT"
        fi
    else
        echo "❓ UNKNOWN RESPONSE: ${RESPONSE:0:200}" | tee -a "$OUTPUT"
    fi
}

# Test 1: Nemotron 3 Ultra (Opus 5) - PROJECT_1
test_model \
    "NVIDIA_API_KEY_PROJECT_1 → Nemotron 3 Ultra (claude-opus-5)" \
    "$NVIDIA_API_KEY_PROJECT_1" \
    "PROJECT_1" \
    16384

# Test 2: Nemotron 3 Ultra (Sonnet 5) - PROJECT_2
test_model \
    "NVIDIA_API_KEY_PROJECT_2 → Nemotron 3 Ultra (claude-sonnet-5)" \
    "$NVIDIA_API_KEY_PROJECT_2" \
    "PROJECT_2" \
    16384

# Test 3: Nemotron 3 Ultra (Sonnet 5 1M) - PROJECT_3
test_model \
    "NVIDIA_API_KEY_PROJECT_3 → Nemotron 3 Ultra (claude-sonnet-5-1m)" \
    "$NVIDIA_API_KEY_PROJECT_3" \
    "PROJECT_3" \
    16384

# Test 4: Nemotron 3 Ultra (Haiku 4.5) - PROJECT_4
test_model \
    "NVIDIA_API_KEY_PROJECT_4 → Nemotron 3 Ultra (claude-haiku-4-5)" \
    "$NVIDIA_API_KEY_PROJECT_4" \
    "PROJECT_4" \
    16384

echo "" | tee -a "$OUTPUT"
echo "============================================================" | tee -a "$OUTPUT"
echo "ALL TESTS COMPLETE" | tee -a "$OUTPUT"
echo "Configuration: All 4 models use Nemotron 3 Ultra with 4 independent API keys" | tee -a "$OUTPUT"
echo "Total combined RPM: ~80 (20 RPM per key)" | tee -a "$OUTPUT"
echo "Results saved to: $OUTPUT" | tee -a "$OUTPUT"
echo "============================================================" | tee -a "$OUTPUT"