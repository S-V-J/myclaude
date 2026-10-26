#!/bin/bash
# test_vision_alternatives.sh — Find a working vision model
set -a; source .env; set +a

IMAGE_URL="https://assets.ngc.nvidia.com/products/api-catalog/phi-3-5-vision/example1b.jpg"
KEY="$NVIDIA_API_KEY_1"

VISION_MODELS=(
  "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
  "nvidia/nemotron-3.5-super-vl-120b-a12b"
  "meta/llama-3.2-11b-vision-instruct"
  "meta/llama-3.2-90b-vision-instruct"
  "microsoft/phi-3-vision-128k-instruct"
)

echo "============================================================"
echo "  VISION MODEL AVAILABILITY SCAN"
echo "============================================================"

for MODEL in "${VISION_MODELS[@]}"; do
    echo ""
    echo "━━━ Testing: $MODEL ━━━"

    cat > /tmp/vision_alt.json <<EOF
{
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "What is in this image? One sentence."},
        {"type": "image_url", "image_url": {"url": "$IMAGE_URL"}}
      ]
    }
  ],
  "model": "$MODEL",
  "max_tokens": 128,
  "temperature": 0.6,
  "stream": false
}
EOF

    HTTP_CODE=$(curl -s -o /tmp/vision_alt_resp.json -w "%{http_code}" \
        https://integrate.api.nvidia.com/v1/chat/completions \
        -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d @/tmp/vision_alt.json \
        --max-time 60)

    if [ "$HTTP_CODE" = "200" ]; then
        CONTENT=$(python3 -c "
import json
d=json.load(open('/tmp/vision_alt_resp.json'))
msg = d['choices'][0]['message']
print(msg.get('content','')[:120])
" 2>&1)
        echo "  ✅ HTTP 200 → $CONTENT"
    else
        ERROR=$(python3 -c "
import json
try:
    d=json.load(open('/tmp/vision_alt_resp.json'))
    print(d.get('error',{}).get('message','unknown')[:120])
except:
    print(open('/tmp/vision_alt_resp.json').read()[:120])
" 2>&1)
        echo "  ❌ HTTP $HTTP_CODE → $ERROR"
    fi
done

echo ""
echo "============================================================"
echo "  SCAN COMPLETE — Use whichever model returned ✅"
echo "============================================================"
