#!/bin/bash
# test_keys_vision.sh - Vision probe for nvidia/nemotron-3-nano-omni-30b-a3b-reasoning
# Uses the OpenAI-compatible image_url block + reasoning_budget (per NVIDIA docs #82).
set -a; source "$(dirname "$0")/.env"; set +a
URL="https://integrate.api.nvidia.com/v1/chat/completions"
MODEL="nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
IMG="https://assets.ngc.nvidia.com/products/api-catalog/phi-3-5-vision/example1b.jpg"

echo "================ VISION PROBE (stream=false) ================"
for i in 1 2 3 4 5 6; do
  KV="NVIDIA_API_KEY_${i}"; KEY="${!KV}"
  cat > /tmp/v.json <<JSON
{"model":"$MODEL","max_tokens":64,"reasoning_budget":16384,"temperature":0.6,"top_p":0.95,"stream":false,
 "messages":[{"role":"user","content":[
   {"type":"text","text":"What is in this image? One sentence."},
   {"type":"image_url","image_url":{"url":"$IMG"}}]}]}
JSON
  CODE=$(curl -s -o /tmp/vr.json -w "%{http_code}" --max-time 90 "$URL" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -H "Accept: application/json" -d @/tmp/v.json)
  RAW=$(cat /tmp/vr.json)
  if [ "$CODE" = "200" ]; then
    OUT=$(python3 -c "import json;d=json.load(open('/tmp/vr.json'));m=d['choices'][0]['message'];print((m.get('content') or m.get('reasoning') or '')[:60])" 2>/dev/null)
    printf "  KEY_%s: HTTP %s ✅ %s\n" "$i" "$CODE" "$OUT"
  elif echo "$RAW" | grep -qi "Missing request extension"; then
    printf "  KEY_%s: HTTP %s ❌ NVIDIA_500_AXUM_BUG (server-side, not your fault)\n" "$i" "$CODE"
  elif echo "$RAW" | grep -qi "ResourceExhausted"; then
    printf "  KEY_%s: HTTP %s ⚠ CONCURRENCY_503 (retry later / lower parallelism)\n" "$i" "$CODE"
  else
    ERR=$(echo "$RAW" | tr -d '\n' | cut -c1-70)
    printf "  KEY_%s: HTTP %s ❌ %s\n" "$i" "$CODE" "$ERR"
  fi
  sleep 0.5
done
echo "============================================================="
echo "If every KEY shows NVIDIA_500_AXUM_BUG, the vision payload FORMAT"
echo "is correct (matches docs #82) and the failure is the global completions bug."
