#!/bin/bash
# test_vision.sh - Diagnose vision model availability across all 5 keys
set -a; source .env; set +a

MODEL="nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
IMAGE_URL="https://assets.ngc.nvidia.com/products/api-catalog/phi-3-5-vision/example1b.jpg"

echo "============================================================"
echo "  VISION MODEL DIAGNOSTIC"
echo "  Model: $MODEL"
echo "  Image: $IMAGE_URL"
echo "============================================================"
echo ""

# ─── TEST 1: Minimal payload (no reasoning_budget) ───
echo "━━━ TEST 1: Minimal payload (NO reasoning_budget) ━━━"
for i in 1 2 3 4 5; do
    KEY_VAR="NVIDIA_API_KEY_${i}"
    KEY="${!KEY_VAR}"
    
    cat > /tmp/vision_min.json <<EOF
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
  "max_tokens": 256,
  "temperature": 0.6,
  "stream": false
}
EOF

    HTTP_CODE=$(curl -s -o /tmp/vision_resp_${i}.json -w "%{http_code}" \
        https://integrate.api.nvidia.com/v1/chat/completions \
        -H "Authorization: Bearer $KEY" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -d @/tmp/vision_min.json \
        --max-time 60)
    
    echo -n "  KEY_$i: HTTP $HTTP_CODE → "
    if [ "$HTTP_CODE" = "200" ]; then
        CONTENT=$(python3 -c "
import json,sys
try:
    d=json.load(open('/tmp/vision_resp_${i}.json'))
    print(d['choices'][0]['message']['content'][:80])
except Exception as e:
    print(f'PARSE ERROR: {e}')
" 2>&1)
        echo "✅ $CONTENT"
    else
        ERROR=$(python3 -c "
import json
try:
    d=json.load(open('/tmp/vision_resp_${i}.json'))
    print(d.get('error',{}).get('message','unknown')[:100])
except:
    print(open('/tmp/vision_resp_${i}.json').read()[:100])
" 2>&1)
        echo "❌ $ERROR"
    fi
done

echo ""

# ─── TEST 2: With reasoning_budget ───
echo "━━━ TEST 2: WITH reasoning_budget=16384 ━━━"
KEY="${NVIDIA_API_KEY_1}"

cat > /tmp/vision_reasoning.json <<EOF
{
  "messages": [
    {
      "role": "user",
      "content": [
        {"type": "text", "text": "Describe this image in detail."},
        {"type": "image_url", "image_url": {"url": "$IMAGE_URL"}}
      ]
    }
  ],
  "model": "$MODEL",
  "max_tokens": 65536,
  "reasoning_budget": 16384,
  "temperature": 0.6,
  "top_p": 0.95,
  "stream": false
}
EOF

HTTP_CODE=$(curl -s -o /tmp/vision_r.json -w "%{http_code}" \
    https://integrate.api.nvidia.com/v1/chat/completions \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d @/tmp/vision_reasoning.json \
    --max-time 90)

echo "  HTTP $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ]; then
    echo "  ✅ Success"
    python3 -c "
import json
d=json.load(open('/tmp/vision_r.json'))
msg = d['choices'][0]['message']
print(f'  Content: {msg.get(\"content\",\"\")[:150]}')
print(f'  Reasoning: {msg.get(\"reasoning\",\"\")[:150]}')
" 2>&1
else
    echo "  ❌ Failed:"
    cat /tmp/vision_r.json | python3 -m json.tool 2>/dev/null || cat /tmp/vision_r.json
fi

echo ""

# ─── TEST 3: Check if model exists in NVIDIA catalog ───
echo "━━━ TEST 3: List available Nemotron models ━━━"
curl -s https://integrate.api.nvidia.com/v1/models \
    -H "Authorization: Bearer $KEY" | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    models = data.get('data',[])
    nemotron = [m['id'] for m in models if 'nemotron' in m['id'].lower() or 'omni' in m['id'].lower() or 'vision' in m['id'].lower()]
    if nemotron:
        print('  Available vision/nemotron models:')
        for m in sorted(nemotron):
            print(f'    • {m}')
    else:
        print('  ⚠️  No nemotron/omni/vision models found!')
        print(f'  Total models available: {len(models)}')
        for m in models[:10]:
            print(f'    • {m[\"id\"]}')
except Exception as e:
    print(f'  Error parsing model list: {e}')
    print(f'  Raw: {sys.stdin.read()[:200]}')
" 2>&1

echo ""

# ─── TEST 4: Text-only test (verify model works at all) ───
echo "━━━ TEST 4: Text-only (no image) to verify model exists ━━━"
cat > /tmp/text_only.json <<EOF
{
  "messages": [{"role":"user","content":"Say hello in one word."}],
  "model": "$MODEL",
  "max_tokens": 10,
  "stream": false
}
EOF

HTTP_CODE=$(curl -s -o /tmp/text_resp.json -w "%{http_code}" \
    https://integrate.api.nvidia.com/v1/chat/completions \
    -H "Authorization: Bearer $KEY" \
    -H "Content-Type: application/json" \
    -d @/tmp/text_only.json \
    --max-time 30)

echo "  HTTP $HTTP_CODE"
if [ "$HTTP_CODE" = "200" ]; then
    python3 -c "import json; d=json.load(open('/tmp/text_resp.json')); print(f'  ✅ Response: {d[\"choices\"][0][\"message\"][\"content\"]}')"
else
    echo "  ❌ Model may not exist. Error:"
    cat /tmp/text_resp.json
fi

echo ""
echo "============================================================"
echo "  DIAGNOSTIC COMPLETE"
echo "============================================================"
