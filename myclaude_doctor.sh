#!/bin/bash
# myclaude_doctor.sh — full-stack health check. v4.1
# Run after ANY config change. Read-only except /tmp scratch files.
#
# v4.1 vs v4: §3 asserted the OPPOSITE of this LiteLLM's boot contract.
#   v4 flagged any non-class callback as LOOSE -> the CORRECT instance
#   registration (proxy_handler_instance) was reported ❌, and a bare class
#   (which the proxy refuses to boot with) was reported ✅. Inverted:
#   bare class = ❌ "loader rejects", loose function = ❌ "BUG A shape",
#   CustomLogger instance with 6 hooks = ✅. §1's grep string tracks the new
#   build_config.sh success wording. Everything else (timeouts, worker audit,
#   drift counter, guard_grep hardening) is unchanged from v4.
set -uo pipefail
cd "$(dirname "$0")"
source venv/bin/activate 2>/dev/null || true
PASS=0; WARN=0; FAIL=0
ok()   { echo "  ✅ $1"; PASS=$((PASS+1)); }
warn() { echo "  ⚠️  $1"; WARN=$((WARN+1)); }
bad()  { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
# Session baseline, captured at the VERY TOP -- before §1's build_config.sh --check
# imports the guard (every import appends a "module loaded" line), §3 imports again,
# and §5/§6 put ~20 live calls through. Measured 2026-10-26: capturing this at §7
# reported "grew 0 lines" for a run that had already generated 20+ calls, because §7
# itself is read-only. The baseline must precede ALL of the run's traffic.
BASE_LINES=$(wc -l < guard.log 2>/dev/null || echo 0)


echo "═══════════ 1. CONFIG VALIDATION (read-only) ═══════════"
if ./build_config.sh --check >/tmp/bc.log 2>&1; then
  ok "config.yaml valid ($(grep -o '[0-9]* deployments' /tmp/bc.log | head -1))"
  grep -q "callbacks are CustomLogger INSTANCES" /tmp/bc.log \
    && ok "assertion 6 (instance-registration tripwire) active" \
    || warn "assertion-6 wording absent — build_config.sh predates v3.1"
else
  bad "config.yaml INVALID"; sed 's/^/     /' /tmp/bc.log | tail -20
fi

RETIRE_OUT=$(python3 - <<'PY'
import sys, yaml
RETIRED = {
    "nvidia/nemotron-3-super-120b-a12b","nvidia/nemotron-3.5-super-120b-a12b",
    "nvidia/nemotron-4-340b-instruct","nvidia/nemotron-nano-3-30b-a3b",
    "nvidia/llama-3.1-nemotron-ultra-253b-v1","microsoft/phi-3-vision-128k-instruct",
    "meta/llama-3.2-90b-vision-instruct","meta/llama-3.2-11b-vision-instruct",
}
try:
    cfg = yaml.safe_load(open("config.yaml", encoding="utf-8"))
except Exception as e:
    print(f"PARSE_ERROR {e}"); sys.exit(2)
hits = []
for m in (cfg or {}).get("model_list") or []:
    mid = str((m.get("litellm_params") or {}).get("model","")).replace("nvidia_nim/","")
    if mid in RETIRED:
        hits.append(f"{m.get('model_name')} -> {mid}")
print("\n".join(hits))
PY
)
if [ -z "$RETIRE_OUT" ]; then
  ok "no retired-model deployments in config.yaml (YAML-checked, comments ignored)"
else
  bad "retired models present in live deployments:"; echo "$RETIRE_OUT" | sed 's/^/     ❌ /'
fi

grep -q '20240620' models/*.yaml 2>/dev/null && bad "stale vision alias 20240620 present" \
                                              || ok "vision alias unified"
if [ -d gateway ] || [ -f backend_router.py ]; then
  warn "dead gateway code present again — attic it (crashes on import, pins retired models)"
else
  ok "no dead gateway/backend_router code on the live path"
fi

echo "═══════════ 2. ENV FILE ═══════════"
if [ ! -f .env ]; then
  bad ".env missing"
else
  if grep -q $'\r' .env 2>/dev/null; then
    bad ".env has CRLF line endings — bash 'source' silently drops EVERY var. Fix: sed -i 's/\\r\$//' .env"
  else
    ok ".env is LF-clean"
  fi
  PERM=$(stat -c '%a' .env 2>/dev/null)
  [ "$PERM" = "600" ] && ok ".env perms 600" || warn ".env perms $PERM — chmod 600 .env"
  ENVCHK=$(python3 - <<'PY'
import json
raw = open(".env","rb").read().decode("utf-8-sig","replace").replace("\r\n","\n").replace("\r","\n")
env={}
for line in raw.splitlines():
    line=line.strip()
    if line and not line.startswith("#") and "=" in line:
        k,v=line.split("=",1); env[k.strip()]=v.strip().strip('"').strip("'")
missing=[f"NVIDIA_API_KEY_{i}" for i in range(1,7) if not env.get(f"NVIDIA_API_KEY_{i}")]
if not env.get("LITELLM_MASTER_KEY"): missing.append("LITELLM_MASTER_KEY")
print(json.dumps({"missing":missing,
                  "n_keys":sum(1 for k in env if k.startswith("NVIDIA_API_KEY_")),
                  "master_len":len(env.get("LITELLM_MASTER_KEY",""))}))
PY
)
  MISS=$(echo "$ENVCHK" | python3 -c "import json,sys;print(','.join(json.load(sys.stdin)['missing']))")
  NK=$(echo "$ENVCHK"   | python3 -c "import json,sys;print(json.load(sys.stdin)['n_keys'])")
  ML=$(echo "$ENVCHK"   | python3 -c "import json,sys;print(json.load(sys.stdin)['master_len'])")
  [ -z "$MISS" ] && ok "all 6 NVIDIA keys + master present (master ${ML} chars)" || bad "env missing: $MISS"
  [ "$NK" -eq 6 ] && ok "6 API keys parsed" || bad "only $NK/6 keys parsed"
fi
[ -f tests/env.sh ] && ok "tests/env.sh present (source before manual curls)" \
                    || warn "tests/env.sh missing — manual \$LITELLM_MASTER_KEY sends an empty key"

echo "═══════════ 3. DEPS / MODULES / CALLBACK SHAPE ═══════════"
python3 -c "import psutil,PIL,yaml,litellm" 2>/dev/null \
  && ok "deps import (psutil/Pillow/pyyaml/litellm)" \
  || bad "missing dep: pip install psutil Pillow pyyaml 'litellm[proxy]'"

# ONE stable token line. Semantics now match the installed loader:
#   BAD=bare-class(...)  -> proxy crash-loops at boot (ValueError)
#   BAD=loose-fn(...)    -> BUG A: non-stream 400/500
#   INST=ConcurrencyGuard + MISS=none + BASE=CustomLogger -> ✅
SHAPE=$(python3 - <<'PY'
import importlib, sys
try:
    import concurrency_guard as g
except Exception as e:
    print(f"IMPORT_FAIL {e}"); sys.exit(0)
import yaml
cfg = yaml.safe_load(open("config.yaml", encoding="utf-8")) or {}
cb = ((cfg.get("litellm_settings") or {}).get("callbacks")) or []
bad=[]
for dot in cb:
    m,_,a = str(dot).rpartition(".")
    if m != "concurrency_guard": continue
    try: obj = getattr(importlib.import_module(m), a)
    except Exception: bad.append(f"{dot}?unresolvable"); continue
    if isinstance(obj, type):
        bad.append(f"{dot}=bare-class(loader-rejects)"); continue
    if callable(obj) and not hasattr(obj, "async_post_call_success_hook"):
        bad.append(f"{dot}=loose-fn(BUG-A)"); continue
    try:
        from litellm.integrations.custom_logger import CustomLogger
        if not isinstance(obj, CustomLogger):
            bad.append(f"{dot}={type(obj).__name__}!CustomLogger")
    except ImportError:
        pass
NEED=['async_pre_call_hook','async_post_call_success_hook','async_post_call_failure_hook',
      'async_post_call_streaming_iterator_hook','async_log_success_event','async_log_failure_event']
inst = getattr(g,'proxy_handler_instance',None)
miss=[n for n in NEED if inst is None or not hasattr(inst,n)]
kind = 'ABSENT' if inst is None else type(inst).__name__
print(f"OK H={len(g.logger.handlers)} "
      f"BASE={'CustomLogger' if getattr(g,'HAS_CUSTOM_LOGGER',False) else 'shim'} "
      f"INST={kind} BAD={','.join(bad) or 'none'} MISS={','.join(miss) or 'none'}")
PY
)
case "$SHAPE" in
  IMPORT_FAIL*) bad "concurrency_guard not importable: ${SHAPE#IMPORT_FAIL } (PYTHONPATH drop-in?)" ;;
  OK*)
    [[ "$SHAPE" == *"H=2"* ]]               && ok "guard logger has 2 handlers (guard.log written)" \
                                             || bad "guard handlers != 2 -> guard.log never written"
    [[ "$SHAPE" == *"BASE=CustomLogger"* ]] && ok "guard subclasses litellm CustomLogger" \
                                             || bad "guard on shim base — litellm not importable at guard import time"
    [[ "$SHAPE" == *"INST=ConcurrencyGuard"* ]] && ok "module-level proxy_handler_instance present" \
                                             || bad "proxy_handler_instance ABSENT — this LiteLLM rejects bare classes at boot"
    if [[ "$SHAPE" == *"BAD=none"* ]]; then ok "all concurrency_guard callbacks are CustomLogger INSTANCES (loader-accepted shape)"
    else BADD=$(printf '%s' "$SHAPE" | sed -n 's/.*BAD=\([^ ]*\).*/\1/p')
         bad "rejected callback shape(s): $BADD — bare class = boot ValueError crash-loop; loose fn = non-stream 400/500. config_base.yaml must use \"concurrency_guard.proxy_handler_instance\""
    fi
    if [[ "$SHAPE" == *"MISS=none"* ]]; then ok "guard instance exposes the full 6-hook surface"
    else MISS=$(printf '%s' "$SHAPE" | sed -n 's/.*MISS=\([^ ]*\).*/\1/p')
         bad "guard instance missing hooks: $MISS"
    fi
    ;;
  *) bad "guard shape probe returned unexpected output: $SHAPE" ;;
esac

echo "═══════════ 4. SERVICES + CONFIG DRIFT + WORKER COUNT ═══════════"
systemctl is-active --quiet myclaude && ok "myclaude.service active" || bad "myclaude.service inactive"
systemctl is-active --quiet nginx    && ok "nginx.service active"    || bad "nginx inactive"
# nginx -t needs root only to open the error log; the sudo credential cache can
# expire mid-session. The old form tried `sudo -n nginx -t || nginx -t` and sent
# both to /dev/null -- but bare `nginx -t` as non-root ALSO fails (error log /
# pid permissions), so an AUTH expiry was indistinguishable from a BROKEN CONFIG
# and false-FAILed a provably healthy stack (manual nginx -t passed, nginx was
# serving, all 16 section-6 cells returned HTTP 200 through it). Separate the two
# failure modes, and never discard nginx's own output.
if sudo -n nginx -t >/tmp/mc_nginx_t.log 2>&1; then
  ok "nginx config syntax valid"
elif grep -qiE "a password is required|a terminal is required|no askpass|sudo:" /tmp/mc_nginx_t.log; then
  warn "nginx -t NOT verified this pass: sudo credentials expired (run 'sudo -v', then re-run doctor)"
else
  bad "nginx -t FAILED:"; sed 's/^/     /' /tmp/mc_nginx_t.log | tail -6
fi
LP=$(cat .litellm_port 2>/dev/null); NP=$(cat .nginx_port 2>/dev/null)
[ -n "$LP" ] && ok "litellm port=$LP" || bad ".litellm_port missing"
[ -n "$NP" ] && ok "nginx port=$NP"   || bad ".nginx_port missing (claude cannot connect)"
(sudo -n systemctl show myclaude -p Environment 2>/dev/null || systemctl show myclaude -p Environment 2>/dev/null) \
  | grep -q "PYTHONPATH" && ok "systemd drop-in PYTHONPATH present" \
                         || warn "no PYTHONPATH in unit env — run ./myclaude.sh start once"

# Guard state is process-local => more workers => real cap = 14 x N => 16-wall returns.
# UNIT-PORT INTEGRITY. Two distinct failure modes, two checks, deliberately
# separated -- conflating them is what made the previous version of this block
# false-FAIL a healthy sed-managed system.
#
#  (1) UNMANAGED UNITS. Any unit that myclaude.sh never rewrites -- the user
#      manager, /etc/systemd/user, vendor dirs -- pointing at OUR config.yaml
#      with a literal --port. This is exactly what litellm-myclaude.service did
#      (Aug 9, Restart=always, RestartSec=5, Linger=yes): a second full proxy on
#      the same config, doubling the guard cap past NVIDIA's 16-worker wall,
#      invisible for five sessions because the old section 4 inspected only the
#      SYSTEM unit. Hard FAIL: nothing regenerates those files, so a literal
#      port there is a static port.
#      The masked unit is a symlink to /dev/null, so [ -f ] is false for it and
#      this loop skips it by construction -- the mask and the check agree.
#
#  (2) MANAGED-UNIT DRIFT. The system unit's EFFECTIVE port versus .litellm_port.
#      Read from `systemctl show -p ExecStart`, which reports argv AFTER systemd
#      substitution, so this single check is correct under BOTH architectures:
#      the sed form (unit carries a literal number rewritten each start) and the
#      drop-in form (unit carries ${MYCLAUDE_LITELLM_PORT}). It catches the real
#      failure -- sed anchors silently failing to match after a hand-edit or a
#      re-render -- which is the only reason the sed architecture is watchable
#      at all. With this check in place, converting the unit to the variable
#      form buys nothing that is not already monitored.
PINNED=""
for U in "$HOME/.config/systemd/user/"*.service \
         /etc/systemd/user/*.service /usr/lib/systemd/user/*.service; do
  [ -f "$U" ] || continue
  grep -q "myclaude/config.yaml" "$U" 2>/dev/null || continue
  if grep -qE -- '--port[= ][0-9]+' "$U" 2>/dev/null; then
    PINNED="$PINNED $U"
  fi
done
if [ -n "$PINNED" ]; then
  bad "unmanaged unit(s) pin our config.yaml to a literal port:$PINNED"
  echo "     -> fix per unit: systemctl --user disable --now <name>; rm the file; then mask it."
else
  ok "no unmanaged (user/vendor) unit pins our config.yaml to a literal port"
fi
EFF=$(systemctl show myclaude -p ExecStart --no-pager 2>/dev/null \
      | grep -oE -- '--port[= ][0-9]+' | grep -oE '[0-9]+' | head -1)
SAVED_LP=$(cat .litellm_port 2>/dev/null || echo "")
if [ -z "$EFF" ]; then
  warn "could not read the unit's effective --port (unit not loaded?)"
elif [ -z "$SAVED_LP" ]; then
  warn ".litellm_port missing -- run 'myclaude' once"
elif [ "$EFF" = "$SAVED_LP" ]; then
  ok "unit port $EFF == .litellm_port (dynamic allocation is reaching the unit)"
else
  bad "unit port $EFF != .litellm_port $SAVED_LP -- myclaude.sh sed anchors failed"
  echo "     -> fix: myclaude stop && myclaude   (rebuilds the unit's port from get_free_port)"
fi

NW=$(grep -oE -- '--num[_-]workers[= ][0-9]+' /etc/systemd/system/myclaude.service 2>/dev/null | grep -oE '[0-9]+$' | head -1)
NW=${NW:-1}
LWC=$(pgrep -fc 'litellm --config' 2>/dev/null || echo 0)
if [ "${NW:-1}" -le 1 ] && [ "${LWC:-0}" -le 1 ]; then
  ok "single LiteLLM process (guard state is process-local; cap really is 14/key)"
else
  bad "num_workers=$NW, litellm procs=$LWC -> effective cap is 14 x N; remove --num_workers / kill orphans"
fi

CUR=$(sha256sum config.yaml 2>/dev/null | awk '{print $1}')
SAVED=$(cat .config_sha 2>/dev/null || echo "")
if [ -z "$SAVED" ]; then warn "no .config_sha — run ./myclaude.sh start to stamp it"
elif [ "$CUR" = "$SAVED" ]; then ok "config.yaml matches the exact bytes LiteLLM booted with (${CUR:0:12})"
else warn "config.yaml CHANGED since last start (${SAVED:0:8} → ${CUR:0:8}) — ./myclaude.sh restart"
fi

echo "═══════════ 5. LIVE ENDPOINTS (ladder probe, HARD-BOUNDED) ═══════════"
if [ ! -f tests/probe_live_endpoints.py ]; then
  bad "tests/probe_live_endpoints.py missing"
else
  timeout 300 python3 tests/probe_live_endpoints.py --key 1 >/tmp/ple.log 2>&1
  case $? in
    0)   ok "every model in config.yaml answers a live POST in >=1 shape"; grep -E '^ *✅' /tmp/ple.log | sed 's/^/     /' | head -6 ;;
    124) bad "probe exceeded 300s and was KILLED — NVIDIA stalling; re-run --key 2" ;;
    *)   bad "dead/unreachable endpoints:"; grep '❌' /tmp/ple.log | sed 's/^/     /' | head -12 ;;
  esac
fi

echo "═══════════ 6. ANTHROPIC PATH (/v1/messages — what Claude Code speaks) ═══════════"
if [ ! -f tests/diag_paths.py ]; then
  bad "tests/diag_paths.py missing — /v1/messages has NEVER been verified"
else
  timeout 300 python3 tests/diag_paths.py >/tmp/dp.log 2>&1
  case $? in
    0) ok "/v1/messages + /v1/chat/completions healthy (stream AND non-stream)"
       grep -E '^ *(✅|❌) (msgs|chat)/' /tmp/dp.log | sed 's/^/     /' ;;
    124) bad "probe exceeded 300s and was KILLED — full bodies:"
         sed -n '/FULL RESPONSE BODY/,/└/p' /tmp/dp.log | head -30 | sed 's/^/     /' ;;
    *)   bad "path NOT fully confirmed — full bodies:"
         sed -n '/FULL RESPONSE BODY/,/└/p' /tmp/dp.log | head -40 | sed 's/^/     /'
         grep -E '^ *(✅|❌) (msgs|chat)/' /tmp/dp.log | sed 's/^/     /'
         grep -q 'async_post_call_success_hook' /tmp/dp.log \
           && echo "     🎯 ATTR ERROR STILL PRESENT — the RUNNING process is not on the instance registration" ;;
  esac
fi

echo "═══════════ 7. GUARD VISIBILITY (guard.log / litellm.log / journal) ═══════════"
# PER-SOURCE AUTHORITY -- forced by measurement on 2026-10-26, not by taste.
# The guard's logger has TWO handlers by design:
#   FileHandler           -> guard.log     (durable, complete)
#   StreamHandler(stderr) -> journald      (partial, rolling copy)
# So every GUARD-authored event exists in BOTH sources, but the journal only holds
# the last N lines. Counting guard.log + journal together DOUBLE-COUNTS recent
# events and UNDER-counts old ones: the doctor printed guard-failures=268 while
# guard.log holds 251 and the journal 19 -- the same 19 events, twice. Rule:
#   guard-authored patterns  -> count guard.log ONLY (fallback litellm.log)
#   litellm-authored patterns -> count the journal ONLY
#   never sum the SAME pattern across sources.
# Existence checks MAY union (a line missing from one sink is not a missing
# event), but every NUMBER comes from exactly one named source.
gl_count() {  # guard-authored event count. guard.log is the authority when present.
    local pat="$1" f=guard.log
    [ -f "$f" ] || f=litellm.log
    [ -f "$f" ] || { echo 0; return; }
    grep -ciE -e "$pat" "$f" </dev/null 2>/dev/null || true
}
gl_lines() {  # the matching lines themselves, FILE ORDER (= chronological), no sort.
    local pat="$1" f=guard.log
    [ -f "$f" ] || f=litellm.log
    [ -f "$f" ] || return 0
    grep -hiE -e "$pat" "$f" </dev/null 2>/dev/null || true
}
# Journal readability must be DETECTED, not assumed. sudo -n never prompts -- it
# fails fast, its error goes to stderr, and '2>/dev/null' would turn "not allowed
# to look" into a silent zero. That is the exact trap the nginx check had, and the
# KB flagged it for journalctl inside $( ): an expired cache must never masquerade
# as "no events".
JLINES=$(sudo -n journalctl -u myclaude --no-pager -n 2000 </dev/null 2>/dev/null | wc -l)
if [ "${JLINES:-0}" -gt 0 ]; then JOK=1; else JOK=0; fi
jc_count() {  # litellm-authored event count, journal only. Unreadable -> empty string.
    local pat="$1"
    [ "$JOK" -eq 1 ] || { echo ""; return; }
    sudo -n journalctl -u myclaude --no-pager -n 2000 </dev/null 2>/dev/null \
      | grep -ciE -e "$pat" || true
}
guard_grep() {  # EXISTENCE union across sinks. Never use its output as a count.
    local pat="$1"
    { [ -f guard.log ]   && grep -hiE -e "$pat" guard.log   </dev/null 2>/dev/null
      [ -f litellm.log ] && grep -hiE -e "$pat" litellm.log </dev/null 2>/dev/null
      if [ "$JOK" -eq 1 ]; then sudo -n journalctl -u myclaude --no-pager -n 2000 </dev/null 2>/dev/null | grep -iE -e "$pat"; fi
      true; } | sort -u
}

[ -f guard.log ] && ok "guard.log exists ($(wc -l < guard.log) lines)" \
                 || bad "guard.log absent -> guard module was NEVER imported by the proxy process"
WIRED=$(guard_grep "guard: module loaded")
[ -n "$WIRED" ] && { ok "guard WIRED in the proxy process"
      # DISPLAY must be CHRONOLOGICAL. sort -u makes '23:13:02' the maximum of a
      # text sort, so §7 had been printing an Oct-25 23:13 line as "the latest"
      # while the newest was Oct-26 07:29 -- measured against ground truth this
      # session. Tail the FILE, then filter; never sort-then-tail a timestamp.
      gl_lines "guard: module loaded" | tail -1 | sed 's/^/     /'; } \
               || bad "no 'module loaded' — callbacks dead. Check PYTHONPATH drop-in + journal"
SINGLE=$(guard_grep "proxy_handler_instance")
[ -n "$SINGLE" ] && ok "singleton instance referenced in logs" \
                 || ok "guard silent on the singleton path (correct: it names the instance only when misconfigured)"
ENGAGED=$(guard_grep "guard: (new bucket|sweeper started)")
[ -n "$ENGAGED" ] && { ok "guard ENGAGED (buckets/sweeper logged)"
      gl_lines "guard: (new bucket|sweeper started)" | tail -8 | sed 's/^/     /'; } \
                || warn "guard wired but no bucket lines yet — normal before traffic; run tests/probe_proxy.py"

DRIFT=$(gl_count "got non-dict data")
[ "$DRIFT" -eq 0 ] && ok "no signature-drift errors (guard is genuinely acquiring slots)" \
                   || bad "$DRIFT signature-drift lines — guard INERT; LiteLLM changed its hook dispatch"
QT=$(gl_count "guard: queue timeout")
RC=$(gl_count "SWEeper reclaiming")
PCF=$(gl_count "post_call_failure released")
FL=$(gl_count "guard: failure")
# 'cooldown' is litellm-authored: guard.log holds ZERO matches for the word
# (measured). But the router also emits a STATE DUMP, 'Cooldown Deployments=...',
# which is not an event: all 40 journal matches on 2026-10-26 were one dump from a
# single PID at a single instant (Oct 25 07:57:51). Subtract the dump lines and
# report both numbers, so a state echo can never again be read as 40 cooldowns.
COOL_ALL=$(jc_count "cooldown")
COOL_DUMP=$(jc_count "Cooldown Deployments=")
if [ "$JOK" -eq 0 ]; then
  COOL="?"
elif [ -z "$COOL_ALL" ]; then
  COOL=0
else
  COOL=$((COOL_ALL - ${COOL_DUMP:-0}))
fi
# ResourceExhausted is guard-authored (its own 503 path); 'Worker local total' is
# litellm-authored. DIFFERENT signatures from DIFFERENT sources -- adding those is
# safe; adding the same signature across sources is what produced 268.
RXH_G=$(gl_count "ResourceExhausted")
RXH_J=$(jc_count "Worker local total"); RXH_J=${RXH_J:-0}
RXH=$((RXH_G + RXH_J))
echo "     queue-timeouts: $QT | sweeper-reclaims: $RC | post-call-failure-releases: $PCF"
echo "     guard-failures: $FL (guard.log, the authority) | ResourceExhausted: $RXH"
if [ "$JOK" -eq 0 ]; then
  warn "journal unreadable this pass (sudo -n refused) — litellm-authored counters (cooldown events, 'Worker local total') UNVERIFIED. Run 'sudo -v' and re-run."
else
  echo "     cooldown-events: $COOL (state-dump lines excluded: ${COOL_DUMP:-0})"
fi
if [ "$RC" -gt 0 ]; then
  warn "sweeper reclaimed $RC leaked slot(s) — a release path is MISSING for this call shape; the ${RC:+1200s} backstop is the only thing that freed them"
  gl_lines "SWEeper reclaiming" | tail -3 | sed 's/^/     /'
fi
[ "$RXH" -gt 0 ] && bad "$RXH ResourceExhausted reached a client — cap NOT enforced"
NOW_LINES=$(wc -l < guard.log 2>/dev/null || echo 0)
echo "     (guard.log grew $((NOW_LINES - ${BASE_LINES:-0})) lines during this run; totals above are cumulative since the file's start)"

echo "═══════════ SUMMARY ═══════════"
echo "  PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  🟢 READY — next: python3 tests/probe_proxy.py --burst 8"
else echo "  🔴 FIX THE  ITEMS ABOVE BEFORE LAUNCHING claude"; fi
exit $((FAIL > 0))
