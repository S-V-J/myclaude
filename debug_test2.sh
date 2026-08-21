#!/bin/bash
set -euo pipefail

declare -A MODELS=(
    ["claude-opus-5"]="PROJECT_1"
    ["claude-sonnet-5"]="PROJECT_2"
    ["claude-sonnet-5-1m"]="PROJECT_3"
    ["claude-haiku-4-5"]="PROJECT_4"
)

test_model() {
    local model="$1"
    local project="${MODELS[$model]}"

    echo -n "Testing $model (Nemotron 3 Ultra, $project)... "

    local response
    response=$(curl -s --max-time 30 \
        -H "Authorization: Bearer sk-local-proxy-key" \
        -H "Content-Type: application/json" \
        -X POST "http://localhost:4000/v1/chat/completions" \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word\"}],\"max_tokens\":20}" 2>&1) || true

    echo "RAW RESPONSE LENGTH: ${#response}"

    if echo "$response" | grep -q '"choices"'; then
        local content
        content=$(python3 /home/ML/myclaude/debug_test.py "$response")
        echo "PYTHON OUTPUT: $content"
        echo "PASS: $model - Response: ${content:-'(empty)'}"
        return 0
    elif echo "$response" | grep -q '"error"'; then
        echo "FAIL: error"
        return 1
    else
        echo "FAIL: unexpected"
        return 1
    fi
}

echo "Before loop"
for model in "${!MODELS[@]}"; do
    test_model "$model"
done
echo "After loop"