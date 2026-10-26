#!/bin/bash
# myclaude.sh - Port manager + systemd launcher for MyClaude Proxy
# v6: v5 + (a) reset-failed before restart, because a callback ValueError loop
#         latches the unit in 'failed' with the start-limit hit and a plain
#         restart then fails without ever running ExecStart;
#       (b) EARLY BAIL: if the unit reports 'failed', abort in ~1s instead of
#         burning 120s polling a port that can never open;
#       (c) stop) sweeps stray litellm processes bound to OUR config.yaml --
#         guard state is process-local, so a second process doubles the cap
#         (14 x 2 = 28/key) and revives NVIDIA's hard 16-worker wall.

MYCLAUDE_DIR="$HOME/myclaude"
DOTENV="$MYCLAUDE_DIR/.env"
cd "$MYCLAUDE_DIR" || { echo "❌ cannot cd $MYCLAUDE_DIR"; exit 1; }

if [ -z "$VIRTUAL_ENV" ] && [ -f venv/bin/activate ]; then
    source venv/bin/activate
fi

# --- BULLETPROOF .env LOADER ------------------------------------------------
if [ ! -f "$DOTENV" ]; then
    echo "❌ $DOTENV missing"; exit 1
fi
_ENV_EXPORTS=$(python3 - "$DOTENV" <<'PY'
import shlex, sys
raw = open(sys.argv[1], "rb").read().decode("utf-8-sig", "replace")
raw = raw.replace("\r\n", "\n").replace("\r", "\n")
import re
for line in raw.splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    k, v = k.strip(), v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
        print(f"export {k}={shlex.quote(v)}")
PY
)
if [ -z "$_ENV_EXPORTS" ]; then
    echo "❌ .env parser produced 0 exports — file unreadable/empty?"; exit 1
fi
eval "$_ENV_EXPORTS"

# --- FAIL FAST: every var the proxy needs must now be in the shell ----------
_MC_MISSING=""
for _i in 1 2 3 4 5 6; do
  eval "_v=\${NVIDIA_API_KEY_$_i:-}"
  [ -n "$_v" ] || _MC_MISSING="$_MC_MISSING NVIDIA_API_KEY_$_i"
done
[ -n "${LITELLM_MASTER_KEY:-}" ] || _MC_MISSING="$_MC_MISSING LITELLM_MASTER_KEY"
if [ -n "$_MC_MISSING" ]; then
  echo "❌ .env did not load (missing:$_MC_MISSING)"
  echo "   parser emitted: $(echo "$_ENV_EXPORTS" | wc -l) export lines"
  exit 1
fi
echo "✅ .env loaded via python parser (6 keys + master)"

get_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
}

LITELLM_PORT="${MYCLAUDE_LITELLM_PORT:-$(get_free_port)}"
NGINX_PORT="${MYCLAUDE_NGINX_PORT:-$(get_free_port)}"

wait_for() {   # wait_for <url> <tries> <label>
    local url="$1" tries="$2" label="$3" i
    for i in $(seq 1 "$tries"); do
        if curl -sf -o /dev/null --max-time 3 "$url"; then
            echo "✅ $label ready (${i}s)"; return 0
        fi
        sleep 1
    done
    echo "❌ $label NOT ready after ${tries}s"; return 1
}

case "$1" in
    start|"")
        echo "🚀 Starting MyClaude Proxy System..."

        echo "🧹 Cleaning up old port and PID files..."
        rm -f .litellm_port .nginx_port .litellm_pid .nginx_pid

        echo "🔨 Rebuilding config.yaml..."
        if [ -x ./build_config.sh ]; then
            ./build_config.sh || { echo "❌ build_config.sh failed — aborting."; exit 1; }
        else
            echo "❌ build_config.sh not found/executable. Cannot proceed."; exit 1
        fi
        # record the EXACT bytes this launch will serve (doctor compares sha)
        sha256sum config.yaml | awk '{print $1}' > .config_sha

        echo "$LITELLM_PORT" > .litellm_port
        echo "$NGINX_PORT"   > .nginx_port
        echo "✅ LiteLLM port: $LITELLM_PORT    Nginx port: $NGINX_PORT"

        echo "⚙️ Ensuring systemd drop-in (WorkingDirectory/PYTHONPATH/guard caps)..."
        sudo mkdir -p /etc/systemd/system/myclaude.service.d
        sudo tee /etc/systemd/system/myclaude.service.d/myclaude.conf >/dev/null <<EOF
[Service]
WorkingDirectory=$MYCLAUDE_DIR
Environment="PYTHONPATH=$MYCLAUDE_DIR"
Environment="MYCLAUDE_MAX_INFLIGHT=14"
Environment="MYCLAUDE_ACQUIRE_TIMEOUT=120"
# max_hold MUST exceed the longest LEGITIMATE hold. num_retries(3) x timeout(600)
# = 1800s worst case, and a 1222s hold was measured on 2026-10-26 against the
# guard default of 1200s. The sweeper has no liveness check (it compares only
# now-ts > max_hold), so a false reclaim frees the slot WHILE ITS CALL STILL
# RUNS: in-flight is under-counted and the guard OVER-ADMITS toward NVIDIA's
# 16-worker wall -- the exact ResourceExhausted 503 this guard exists to
# prevent. 2400 > 1800 with margin. Consequence: a reclaim at ~2400s is now
# strong evidence of a GENUINE leak (see doctor s7 warn + tests/probe_cancel.py).
Environment="MYCLAUDE_MAX_HOLD=2400"
EOF

        echo "⚙️ Updating myclaude.service with port $LITELLM_PORT..."
        sudo sed -i "s/--port [0-9]\+/--port $LITELLM_PORT/g" /etc/systemd/system/myclaude.service
        sudo sed -i "s/Environment=\"PORT=[0-9]\+\"/Environment=\"PORT=$LITELLM_PORT\"/g" /etc/systemd/system/myclaude.service
        sudo systemctl daemon-reload

        echo "⚙️ Generating Nginx config for port $NGINX_PORT..."
        sudo mkdir -p /etc/nginx/conf.d
        cat << LIMIT_EOF | sudo tee /etc/nginx/conf.d/myclaude-limit.conf >/dev/null
# Per-API-key rate limit (30 r/m) — NVIDIA free tier is ~40 r/m; stay under 30.
limit_req_zone \$http_authorization zone=api_key_limit:10m rate=30r/m;
LIMIT_EOF

        cat << NGINX_EOF | sudo tee /etc/nginx/sites-available/myclaude >/dev/null
server {
    listen $NGINX_PORT;
    listen [::]:$NGINX_PORT;
    server_name localhost _;

    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options DENY always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;

    client_max_body_size 50M;
    client_body_timeout 120s;
    client_header_timeout 60s;
    send_timeout 3600s;

    location / {
        limit_req zone=api_key_limit burst=10 nodelay;
        limit_req_status 429;
        limit_req_log_level warn;

        proxy_pass http://127.0.0.1:$LITELLM_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_connect_timeout 10s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;

        # CRITICAL for Claude Code: SSE must not be buffered
        proxy_buffering off;
        proxy_request_buffering off;
    }

    location = /health {
        access_log off;
        return 200 "healthy\n";
        add_header Content-Type text/plain;
    }

    # Never expose LiteLLM admin surface
    location ~ ^/(admin|config|keys|spend) {
        deny all;
        return 404;
    }
}
NGINX_EOF

        sudo ln -sf /etc/nginx/sites-available/myclaude /etc/nginx/sites-enabled/myclaude
        if ! sudo nginx -t >/dev/null 2>&1; then
            echo "❌ Nginx config test failed:"; sudo nginx -t; exit 1
        fi

        echo "⚙️ Restarting myclaude.service..."
        # A crash loop (e.g. a callback ValueError at boot) latches the unit in
        # 'failed' with StartLimitBurst exhausted; restart then refuses to run
        # ExecStart at all. Clear the latch first so this attempt is honest.
        sudo systemctl reset-failed myclaude 2>/dev/null || true
        sudo systemctl restart myclaude

        # EARLY BAIL: unit state is authoritative and instant. Do not spend 120s
        # waiting on a process that has already exited.
        BOOT_FAILED=0
        for i in $(seq 1 90); do
            ST=$(systemctl is-active myclaude 2>/dev/null || true)
            if [ "$ST" = "active" ]; then break; fi
            if [ "$ST" = "failed" ]; then BOOT_FAILED=1; break; fi
            sleep 1
        done
        if [ "$BOOT_FAILED" -eq 1 ]; then
            echo "❌ myclaude.service entered 'failed' after ${i}s — aborting early"
            echo "   (no 120s dead poll). Decisive lines:"
            sudo journalctl -u myclaude -n 80 --no-pager 2>/dev/null \
              | grep -E "ValueError|Traceback|Error|error|guard:|callback" | tail -20
            echo "   Full log: sudo journalctl -u myclaude -n 120 --no-pager"
            exit 1
        fi

        if ! wait_for "http://127.0.0.1:$LITELLM_PORT/health/liveliness" 90 "LiteLLM"; then
            wait_for "http://127.0.0.1:$LITELLM_PORT/health" 30 "LiteLLM (/health)" || {
                echo "--- last 40 log lines ---"; sudo journalctl -u myclaude -n 40 --no-pager
                exit 1
            }
        fi

        echo "⚙️ Reloading nginx (backend is warm, no cold-proxy window)..."
        if systemctl is-active --quiet nginx; then
            sudo systemctl reload nginx
        else
            sudo systemctl start nginx
        fi

        if wait_for "http://127.0.0.1:$NGINX_PORT/health" 20 "MyClaude Proxy (nginx)"; then
            echo "✅ MyClaude Proxy is healthy and ready on port $NGINX_PORT!"
        else
            echo "⚠️  nginx health check failed — sudo journalctl -u nginx -n 30"
        fi

        # --- prove the guard module was actually IMPORTED by the proxy -------
        sleep 2
        if grep -q "guard: module loaded" guard.log 2>/dev/null; then
            echo "✅ concurrency_guard WIRED (guard.log: $(grep -m1 'module loaded' guard.log))"
        else
            echo "⚠️  guard.log has no 'module loaded' — callbacks not firing?"
            echo "   Check: PYTHONPATH in /etc/systemd/system/myclaude.service.d/myclaude.conf"
            echo "   And:   sudo journalctl -u myclaude -n 60 | grep -i callback"
        fi

        echo "💡 Tip: Type 'claude' to launch Claude Code connected to this proxy."
        ;;

    restart|--restart)
        echo "🔄 Restarting MyClaude Proxy System..."
        exec bash "$0" start
        ;;

    status)
        echo "📊 MyClaude Status:"
        echo "--- myclaude.service ---"; systemctl status myclaude --no-pager -n 12
        echo ""; echo "--- nginx.service ---"; systemctl status nginx --no-pager -n 12
        echo ""; echo "--- guard (guard.log, last 12) ---"
        tail -n 12 guard.log 2>/dev/null || echo "   (no guard.log yet)"
        echo ""; echo "--- guard (journal fallback) ---"
        sudo journalctl -u myclaude --no-pager -n 300 2>/dev/null \
          | grep -E "guard: (new bucket|sweeper|queue timeout|SWEeper|module)" | tail -8
        ;;

    stop)
        echo "🛑 Stopping MyClaude Proxy System..."
        sudo systemctl stop myclaude
        sudo systemctl stop nginx
        # Strays are a CORRECTNESS bug, not hygiene: concurrency_guard's
        # semaphores are process-local, so N processes on this config permit
        # 14*N in-flight per key and NVIDIA's 16-worker wall returns. Match on
        # the config path (not the binary name) so unrelated litellm installs
        # on this host are never touched.
        PAT="--config $MYCLAUDE_DIR/config.yaml"
        STRAYS=$(pgrep -f -- "$PAT" 2>/dev/null || true)
        if [ -n "$STRAYS" ]; then
            echo "🧹 Stray litellm process(es) holding our config.yaml: $(echo $STRAYS | tr '\n' ' ')"
            echo "   (they double the guard cap; terminating)"
            sudo kill $STRAYS 2>/dev/null || true
            sleep 3
            STRAYS=$(pgrep -f -- "$PAT" 2>/dev/null || true)
            if [ -n "$STRAYS" ]; then
                echo "   still alive, sending SIGKILL: $(echo $STRAYS | tr '\n' ' ')"
                sudo kill -9 $STRAYS 2>/dev/null || true
                sleep 1
            fi
            if pgrep -f -- "$PAT" >/dev/null 2>&1; then
                echo "❌ could not terminate strays — investigate: pgrep -af '$PAT'"
            else
                echo "   ✅ strays cleared"
            fi
        fi
        sudo systemctl reset-failed myclaude 2>/dev/null || true
        rm -f .litellm_port .nginx_port .litellm_pid .nginx_pid .config_sha
        echo "✅ Stopped and cleaned up."
        ;;

    *)
        echo "Usage: myclaude [start|restart|--restart|status|stop]"
        ;;
esac
