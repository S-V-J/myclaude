#!/bin/bash
# build_config.sh - Build config.yaml from 6 modular scenes, then VALIDATE hard.
#   ./build_config.sh          build + validate + stamp .config_sha
#   ./build_config.sh --check  validate the EXISTING config.yaml ONLY (no rewrite)
#                              -> safe for myclaude_doctor.sh (no mtime self-sabotage)
#
# v3.1 CHANGE (forced by the installed LiteLLM's own boot contract):
#   assertion 6 used to REQUIRE a class. This build's
#   callback_utils._loaded_callback_or_raise() REJECTS bare classes at boot
#   ("neither a CustomLogger instance nor a callable"), so the old assertion
#   blessed a config that would crash-loop the proxy 20x. It now requires a
#   CustomLogger INSTANCE and fails the build on a class or a loose function.
set -euo pipefail
CHECK=0; [ "${1:-}" = "--check" ] && CHECK=1
OUTPUT="config.yaml"

if [ "$CHECK" -eq 0 ]; then
  echo "🔨 Building config.yaml from modular scene files..."
  cp config_base.yaml "$OUTPUT"
  SCENES=(
    models/scene_1_default.yaml
    models/scene_2_opus_1m.yaml
    models/scene_3_sonnet.yaml
    models/scene_4_sonnet_1m.yaml
    models/scene_5_vision.yaml
    models/scene_6_orchestration.yaml
  )
  for f in "${SCENES[@]}"; do
    if [ ! -f "$f" ]; then echo "❌ MISSING: $f" >&2; exit 1; fi
    printf '\n' >> "$OUTPUT"
    cat "$f" >> "$OUTPUT"
    echo "  ✓ appended $f"
  done
else
  echo "🔍 Validating existing config.yaml (--check, no rewrite)"
  [ -f "$OUTPUT" ] || { echo "❌ $OUTPUT missing — run ./build_config.sh first"; exit 1; }
fi

python3 - "$CHECK" <<'PY'
import os, sys, yaml
from collections import Counter

check = sys.argv[1] == "1"
cfg = yaml.safe_load(open("config.yaml"))
ml = cfg.get("model_list") or []
c = Counter(m["model_name"] for m in ml)
print(f"{'🔍' if check else '✅'} config.yaml parses — {len(ml)} deployments across {len(c)} aliases")
for a, n in sorted(c.items()):
    print(f"   {a}: {n}")

errs = []
SUPER_ENV = os.getenv("MYCLAUDE_SUPER_MODEL",
                      "nvidia_nim/nvidia/nemotron-3.5-super-vl-120b-a12b")

# ---- 8. LIVE allow-list ----------------------------------------------------
LIVE = {
    "nvidia/nemotron-3-ultra-550b-a55b",
    "nvidia/nemotron-3.5-super-vl-120b-a12b",
    "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning",
    "nvidia/nemotron-3.5-lightning-30b-a3b",
}
# ---- 3. RETIRED registry (each proven dead by live POST; catalog lies) ------
RETIRED = {
    "nvidia/nemotron-3-super-120b-a12b",
    "nvidia/nemotron-3.5-super-120b-a12b",
    "nvidia/nemotron-4-340b-instruct",
    "nvidia/nemotron-nano-3-30b-a3b",
    "nvidia/llama-3.1-nemotron-ultra-253b-v1",
    "microsoft/phi-3-vision-128k-instruct",
    "meta/llama-3.2-90b-vision-instruct",
    "meta/llama-3.2-11b-vision-instruct",
    "deepseek-ai/deepseek-coder-6.7b-instruct",
    "bigcode/starcoder2-15b",
    "mistralai/codestral-22b-instruct-v0.1",
    "ibm/granite-34b-code-instruct",
    "ibm/granite-8b-code-instruct",
    "google/gemma-3-12b-it",
    "google/gemma-3-4b-it",
    "mistralai/mistral-7b-instruct-v0.3",
    "mistralai/mistral-large-2-instruct",
    "01-ai/yi-large",
}

# 1. Scene entry counts (scenes 1-5)
expect = {"claude-opus-5": 12, "claude-opus-5-1m": 12, "claude-sonnet-5": 12,
          "claude-sonnet-5-1m": 12, "claude-3-5-sonnet-20241022-vision": 12}
for a, n in expect.items():
    if c.get(a) != n:
        errs.append(f"entry-count: {a} has {c.get(a)}, expected {n}")

# 2. Unified vision alias (the 20240620 split-pool bug)
if any("20240620" in m["model_name"] for m in ml):
    errs.append("stale vision alias claude-3-5-sonnet-20240620-vision present")

# 3+8. Retired registry + live allow-list
for m in ml:
    mid = str(m.get("litellm_params", {}).get("model", "")).replace("nvidia_nim/", "")
    if mid in RETIRED:
        errs.append(f"RETIRED model in use: {m['model_name']} -> {mid}")
    elif mid not in LIVE:
        errs.append(f"NOT-IN-LIVE-ALLOWLIST: {m['model_name']} -> {mid}")

# 4+5. env-ref integrity and timeout units
for m in ml:
    ak = str(m.get("litellm_params", {}).get("api_key", ""))
    if not ak.startswith("os.environ/NVIDIA_API_KEY_"):
        errs.append(f"{m['model_name']}: api_key not an env ref ({ak[:40]})")
    else:
        try:
            idx = int(ak.rsplit("_", 1)[1])
            if not (1 <= idx <= 6):
                errs.append(f"{m['model_name']}: key index {idx} outside 1..6")
        except ValueError:
            errs.append(f"{m['model_name']}: unparsable api_key ref {ak[:40]}")
    t = m.get("litellm_params", {}).get("timeout")
    if isinstance(t, (int, float)) and t > 3600:
        errs.append(f"{m['model_name']}: timeout={t} looks like milliseconds")

# 6. CALLBACK REGISTRATION SHAPE — v3.1, matching the installed loader.
#    _loaded_callback_or_raise() accepts a CustomLogger INSTANCE or a non-class
#    callable, and REJECTS a bare class. A non-class callable is the v1.x shape
#    that caused BUG A ('function' object has no attribute
#    'async_post_call_success_hook' -> 400/500 on every non-stream call).
#    Therefore the only acceptable shape is: a CustomLogger instance exposing
#    the full hook surface. Both wrongs are now sub-second build failures.
REQUIRED_HOOKS = [
    "async_pre_call_hook",
    "async_post_call_success_hook",
    "async_post_call_failure_hook",
    "async_post_call_streaming_iterator_hook",
    "async_log_success_event",
    "async_log_failure_event",
]
try:
    import importlib
    import concurrency_guard as g          # also proves importability + handlers
    if len(getattr(g, "logger", None).handlers if hasattr(g, "logger") else []) < 2:
        errs.append("concurrency_guard.logger has <2 handlers -> guard.log never written")
    if not hasattr(g, "proxy_handler_instance"):
        errs.append("concurrency_guard has NO module-level proxy_handler_instance "
                    "-> this LiteLLM rejects bare classes at boot")

    cb = ((cfg.get("litellm_settings") or {}).get("callbacks")) or []
    if not cb:
        errs.append("litellm_settings.callbacks is EMPTY -> no concurrency guard at all")
    ours = [str(d) for d in cb if str(d).rpartition(".")[0] == "concurrency_guard"]
    if len(ours) != 1:
        errs.append(f"expected EXACTLY ONE concurrency_guard callback, found {len(ours)}: "
                    f"{ours} -- two => async_pre_call_hook runs twice per request "
                    f"=> double acquisition => halved effective cap per bucket")
    for dot in cb:
        modname, _, attr = str(dot).rpartition(".")
        if modname != "concurrency_guard":
            continue                       # third-party callback: not ours to police
        try:
            obj = getattr(importlib.import_module(modname), attr)
        except Exception as e:
            errs.append(f"callback {dot}: cannot resolve ({e}) — v2.x moved every hook "
                        f"onto the ConcurrencyGuard class; use the instance token")
            continue
        if isinstance(obj, type):
            errs.append(
                f"callback {dot} resolves to the CLASS {obj.__name__}. This LiteLLM "
                f"build rejects bare classes at boot (ValueError: neither a "
                f"CustomLogger instance nor a callable) and would crash-loop the unit. "
                f'Register the singleton instead: "concurrency_guard.proxy_handler_instance"')
            continue
        if callable(obj) and not hasattr(obj, "async_post_call_success_hook"):
            errs.append(
                f"callback {dot} is a bare {type(obj).__name__} (v1.x shape). LiteLLM's "
                f"non-streaming path calls async_post_call_success_hook on it -> 400/500. "
                f'Register "concurrency_guard.proxy_handler_instance" instead.')
            continue
        try:
            from litellm.integrations.custom_logger import CustomLogger
            if not isinstance(obj, CustomLogger):
                errs.append(f"callback {dot} is not a CustomLogger instance "
                            f"(got {type(obj).__name__}) -> loader will reject it at boot")
                continue
        except ImportError:
            pass   # litellm absent at build time; duck-typed hook check below still runs
        miss = [h for h in REQUIRED_HOOKS if not hasattr(obj, h)]
        if miss:
            errs.append(f"callback instance {dot} is missing hooks: {miss}")
except ImportError as e:
    print(f"⚠️  concurrency_guard not importable at build time ({e}); doctor re-checks")

# 9. THINKING DECLARED + BUDGET HEADROOM + NO FORCED STREAMING.
#    Makes "all models have streaming and thinking" a build-time invariant.
#    Key shape is THIS project's: chat_template_kwargs sits DIRECTLY under
#    litellm_params (gen_scenes.py entry()), NOT under extra_body -- a check
#    reading the nested form finds nothing and passes vacuously.
#
#    WHY HEADROOM IS PART OF THIS ASSERTION, NOT A FOLLOW-UP:
#    doctor section 6 shows cells where reasoning consumes the ENTIRE budget and
#    zero answer text is emitted --
#        chat/bare     stream=False  txt=0 think=60  stop=length
#        chat/+temp    stream=False  txt=0 think=65  stop=length
#        msgs/+system  stream=False  txt=0 think=137 stop=max_tokens
#    -- while tests/probe_think_stream.py at max_tokens=512 shows STARVED=0.
#    Starvation is therefore BUDGET-DEPENDENT, not active at 512. That matters
#    because Claude Code's auxiliary calls (session auto-title, rename, context
#    compaction) use SMALL max_tokens. Flipping thinking on without a headroom
#    floor is exactly the change that would regress the non-stream aux path that
#    BUG A and BUG C were fixed for. Declare thinking AND reserve the answer.
for m in ml:
    lp = m.get("litellm_params") or {}
    ctk = lp.get("chat_template_kwargs")
    ctk = ctk if isinstance(ctk, dict) else {}
    et = lp.get("enable_thinking", ctk.get("enable_thinking"))
    think = lp.get("thinking")
    if et is False:
        errs.append(f"{m['model_name']}: enable_thinking is FALSE -- violates the "
                    f"streaming+thinking requirement")
    if et is None and not isinstance(think, dict):
        errs.append(f"{m['model_name']}: thinking is UNDECLARED (no chat_template_kwargs."
                    f"enable_thinking, no top-level enable_thinking, no thinking dict). "
                    f"Runtime-accidental correctness is not a contract: it broke silently "
                    f"for the vision alias until it didn't.")
    if isinstance(think, dict):
        if think.get("type") == "disabled":
            errs.append(f"{m['model_name']}: thinking.type=disabled -- violates the requirement")
        elif think.get("type") not in (None, "enabled"):
            errs.append(f"{m['model_name']}: thinking.type={think.get('type')!r} unrecognised")
    mt = lp.get("max_tokens")
    bud = think.get("budget_tokens") if isinstance(think, dict) else None
    if bud is None:
        bud = lp.get("reasoning_budget")
    if isinstance(bud, int) and isinstance(mt, int) and bud > mt - 1024:
        errs.append(f"{m['model_name']}: reasoning budget {bud} leaves only {mt-bud} tokens "
                    f"of answer headroom (need >=1024) -> reasoning will starve the answer")
    if "stream" in lp:
        errs.append(f"{m['model_name']}: 'stream' set in litellm_params -- BUG-C class. "
                    f"Streaming is REQUEST-level; forcing it here sends an unknown/overridden "
                    f"key to NVIDIA and breaks Claude Code's non-streaming aux calls.")

# 7. Fallback targets must exist in model_list
fb = (cfg.get("router_settings") or {}).get("fallbacks") or []
for entry in fb:
    if isinstance(entry, dict):
        for src, targets in entry.items():
            if src not in c:
                errs.append(f"fallback source {src} is not defined in any scene")
            for t in (targets or []):
                if t not in c:
                    errs.append(f"fallback {src} -> {t}: target alias not defined in any scene")

if errs:
    print("\n❌ CONFIG VALIDATION FAILED:", file=sys.stderr)
    for e in errs:
        print(f"   • {e}", file=sys.stderr)
    sys.exit(1)
print(f"✅ assertions passed (super variant: {SUPER_ENV.replace('nvidia_nim/','')}) — counts, "
      "unified vision, live allow-list, retired registry, key refs 1..6, timeouts in "
      "seconds, callbacks are CustomLogger INSTANCES with full hook surface, "
      "fallback targets exist")
PY

if [ "$CHECK" -eq 0 ]; then
  sha256sum "$OUTPUT" | awk '{print $1}' > .config_sha
  echo "✅ config.yaml successfully built with 6 scenes (+ stamped .config_sha)"
fi
