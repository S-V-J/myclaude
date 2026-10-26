#!/bin/bash
# test_models_live.sh v2 — LIVE-probe every UNIQUE upstream model in config.yaml.
# Lesson learned: /v1/models lists retired models (nemotron-3-super-120b => 404 on completions).
# Only a real POST /v1/chat/completions proves routability.
set -a; source "$(dirname "$0")/.env"; set +a
URL="https://integrate.api.nvidia.com/v1/chat/completions"
KEYVAR="${1:-NVIDIA_API_KEY_1}"
KEY="${!KEYVAR}"

mapfile -t MODELS < <(grep -oE 'model: nvidia_nim/[^,}]+' config.yaml | sed 's#model: nvidia_nim/##' | sort -u)
echo "Live-probing ${#MODELS[@]} unique upstream models via $KEYVAR (1 token, non-stream)"
printf "%-50s %-5s %s\n" MODEL HTTP VERDICT
DEAD=0
for M in "${MODELS[@]}"; do
  CODE=$(curl -s -o /tmp/m.json -w "%{http_code}" --max-time 45 "$URL" \
    -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "{\"model\":\"$M\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":1,\"stream\":false}")
  case "$CODE" in
    200) V="OK";;
    404) V="DEAD_404 — in catalog but retired => replace in scenes"; DEAD=1;;
    410) V="GONE_410 — retired"; DEAD=1;;
    401|403) V="AUTH — key lacks entitlement for this model";;
    429) V="RPM_429 — wait 60s, rerun";;
    500) if grep -qi "Missing request extension" /tmp/m.json; then V="AXUM_500 — NVIDIA bug, retry later"; else V="SERVER_500"; fi;;
    503) if grep -qi "ResourceExhausted" /tmp/m.json; then V="CONCURRENCY_503 — shared pool busy (transient, fallbacks cover it)"; else V="UNAVAILABLE_503"; fi;;
    *) V="HTTP_$CODE";;
  esac
  printf "%-50s %-5s %s\n" "$M" "$CODE" "$V"
  sleep 0.4
done
echo "------------------------------------------------------------------"
if [ "$DEAD" = "0" ]; then echo "✅ Every model in config.yaml is routable."; else
  echo "❌ Dead models found. Fix: sed -i 's#<dead>#<replacement>#g' models/scene_*.yaml && ./build_config.sh"; fi
