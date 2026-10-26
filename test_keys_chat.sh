#!/bin/bash
# test_keys_chat.sh - Probe all 6 NVIDIA keys against nemotron-3-ultra & super.
# Classifies: 200 OK | 500-AXUM(NVIDIA bug) | 503-CONCURRENCY | 429-RPM | 401/403-AUTH | 404-NOTINCATALOG
set -a; source "$(dirname "$0")/.env"; set +a
URL="https://integrate.api.nvidia.com/v1/chat/completions"
MODELS=("nvidia/nemotron-3-ultra-550b-a55b" "nvidia/nemotron-3.5-super-vl-120b-a12b")
declare -A VERDICT

classify() { # $1=http_code $2=body
  local code="$1" body="$2"
  if [ "$code" = "200" ]; then echo "OK"; return; fi
  if echo "$body" | grep -qi "Missing request extension"; then echo "NVIDIA_500_AXUM_BUG"; return; fi
  if echo "$body" | grep -qi "ResourceExhausted\|Worker local total request limit"; then echo "CONCURRENCY_503"; return; fi
  case "$code" in
    429) echo "RPM_429";; 401|403) echo "AUTH_401_403";; 404) echo "NOT_IN_CATALOG_404";;
    500) echo "SERVER_500";; 502|503|504) echo "UPSTREAM_${code}";; *) echo "HTTP_${code}";;
  esac
}

echo "=================================================================="
echo " CHAT MODEL KEY MATRIX  (non-stream probe, max_tokens=8)"
echo "=================================================================="
printf "%-8s %-34s %-6s %-22s %s\n" KEY MODEL HTTP VERDICT SAMPLE
for i in 1 2 3 4 5 6; do
  KV="NVIDIA_API_KEY_${i}"; KEY="${!KV}"
  for M in "${MODELS[@]}"; do
    BODY=$(cat <<JSON
{"model":"$M","messages":[{"role":"user","content":"Write a limerick about GPU computing."}],
 "temperature":1,"top_p":0.95,"max_tokens":8,"stream":false}
JSON
)
    CODE=$(curl -s -o /tmp/r.json -w "%{http_code}" --max-time 60 "$URL" \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
      -H "Accept: application/json" -d "$BODY")
    RAW=$(cat /tmp/r.json)
    V=$(classify "$CODE" "$RAW")
    SAMP=$(python3 -c "import json,sys;d=json.load(open('/tmp/r.json'));print((d.get('choices') or [{}])[0].get('message',{}).get('content','')[:24])" 2>/dev/null)
    [ -z "$SAMP" ] && SAMP=$(echo "$RAW" | tr -d '\n' | cut -c1-24)
    printf "%-8s %-34s %-6s %-22s %s\n" "KEY_$i" "${M##*/}" "$CODE" "$V" "$SAMP"
    VERDICT["KEY_$i|${M##*/}"]="$V"
    sleep 0.3   # stay well under 30 rpm/key during probes
  done
done

echo ""
echo "---------------------- VERDICT -----------------------------------"
AXUM=0; CONC=0; OK=0
for k in "${!VERDICT[@]}"; do
  case "${VERDICT[$k]}" in
    NVIDIA_500_AXUM_BUG) AXUM=$((AXUM+1));;
    CONCURRENCY_503) CONC=$((CONC+1));;
    OK) OK=$((OK+1));;
  esac
done
echo "  OK=$OK  NVIDIA_500_AXUM_BUG=$AXUM  CONCURRENCY_503=$CONC  (of ${#VERDICT[@]})"
if [ "$AXUM" -gt 0 ] && [ "$OK" -eq 0 ]; then
  echo "  ❗ ALL completions return the axum 500 -> NVIDIA server-side bug (forums #382278)."
  echo "     Your configs are fine. Wait for NVIDIA fix / use fallback provider. Do NOT edit scenes."
elif [ "$CONC" -gt 0 ]; then
  echo "  ⚠ Concurrency hits seen -> ensure concurrency_guard.py is loaded (cap 14) + cooldown 30s."
else
  echo "  ✅ Endpoint healthy for this account right now."
fi
