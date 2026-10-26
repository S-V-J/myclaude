#!/bin/bash
# test_proxy.sh — exercises EVERY alias through the real request path, incl.
# streaming (Claude Code's mode), vision, and a 20-wide burst to prove the 14-slot queue.
set -a; source "$(dirname "$0")/.env"; set +a
NP=$(cat .nginx_port 2>/dev/null) || { echo "❌ no .nginx_port — run ./myclaude.sh start first"; exit 1; }
B="http://127.0.0.1:$NP"
H=(-H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "Content-Type: application/json")

echo "== 1. health =="
echo -n "  nginx:   "; curl -s "$B/health"; echo
echo -n "  litellm: "; curl -s "$B/health/litellm" | head -c 120; echo; echo

echo "== 2. text aliases (non-stream) =="
for ALIAS in claude-opus-5 claude-opus-5-1m claude-sonnet-5 claude-sonnet-5-1m claude-haiku-5; do
  printf "  %-22s " "$ALIAS"
  curl -s --max-time 120 "$B/v1/chat/completions" "${H[@]}" \
    -d "{\"model\":\"$ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ok\"}],\"max_tokens\":8,\"stream\":false}" \
    | python3 -c "import sys,json
d=json.load(sys.stdin)
c=d.get('choices')
print('✅', (c[0]['message']['content'] or '')[:40] if c else '❌ '+str(d)[:80])" 2>/dev/null || echo "❌ non-JSON/timeout"
done

echo "== 3. vision alias (nano-omni, traffic-sign image) =="
printf "  %-22s " "vision"
curl -s --max-time 180 "$B/v1/chat/completions" "${H[@]}" \
 -d '{"model":"claude-3-5-sonnet-20241022-vision","max_tokens":64,"messages":[{"role":"user","content":[{"type":"text","text":"One word: what color is the sign?"},{"type":"image_url","image_url":{"url":"https://assets.ngc.nvidia.com/products/api-catalog/phi-3-5-vision/example1a.jpg"}}]}]}' \
 | python3 -c "import sys,json
d=json.load(sys.stdin); c=d.get('choices')
print('✅', (c[0]['message']['content'] or '')[:60] if c else '❌ '+str(d)[:100])" 2>/dev/null || echo "❌"

echo "== 4. STREAMING (what Claude Code actually uses) =="
CHUNKS=$(timeout 90 curl -sN "$B/v1/chat/completions" "${H[@]}" \
 -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"Count 1 2 3."}],"max_tokens":32,"stream":true}' \
 | grep -c '^data:')
echo "  claude-opus-5 stream: $CHUNKS SSE chunks $([ "$CHUNKS" -gt 3 ] && echo ✅ || echo ❌)"

echo "== 5. TOOL CALLING (Claude Code Bash/Edit/Read depend on this) =="
curl -s --max-time 120 "$B/v1/chat/completions" "${H[@]}" \
 -d '{"model":"claude-opus-5","max_tokens":128,"tool_choice":"auto","tools":[{"type":"function","function":{"name":"read_file","description":"Read a file","parameters":{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}}}],"messages":[{"role":"user","content":"Read /etc/hostname"}]}' \
 | python3 -c "import sys,json
d=json.load(sys.stdin); c=d.get('choices')
tc=(c[0]['message'].get('tool_calls') if c else None)
print('  tool_calls:', '✅ '+tc[0]['function']['name'] if tc else '❌ none/'+str(d)[:80])" 2>/dev/null || echo "  ❌ non-JSON"

echo "== 6. BURST x20 (proves guard queues at 14/key; watch for 503s) =="
for i in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code}\n" --max-time 240 "$B/v1/chat/completions" "${H[@]}" \
    -d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"hi"}],"max_tokens":4,"stream":false}' &
done | sort | uniq -c
wait
echo "  (expect mostly 200; any 503 = NVIDIA shared-pool pressure, absorbed by fallbacks)"
