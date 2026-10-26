#!/usr/bin/env python3
"""Direct-to-NVIDIA probe. Adds what the old bash tests missed:
   - SSE streaming parse (reasoning_content vs content, [DONE] sentinel, TTFT)
   - tool_calls probe  (Claude Code ALWAYS sends tools; nemotron-ultra has a known hang-with-tools bug)
   - per-key RPM throttle at 28 (NVIDIA free tier ~40; stay under 30 as you required)
Usage: python3 tests/probe_nvidia.py [--modes text,stream,tools,vision] [--keys 1-6]
"""
import json, os, sys, time, argparse, urllib.request, urllib.error
from collections import defaultdict, deque

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = "https://integrate.api.nvidia.com/v1/chat/completions"
IMG = "https://assets.ngc.nvidia.com/products/api-catalog/phi-3-5-vision/example1a.jpg"
TOOLS = [{"type": "function", "function": {
    "name": "read_file", "description": "Read a file from disk",
    "parameters": {"type": "object", "properties": {"path": {"type": "string"}},
                   "required": ["path"]}}}]

def load_env():
    for line in open(os.path.join(BASE, ".env")):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1); os.environ.setdefault(k.strip(), v.strip().strip('"'))

_thr = defaultdict(deque)
def slot(key_id, rpm=28):
    q = _thr[key_id]; now = time.time()
    while q and q[0] < now - 60: q.popleft()
    if len(q) >= rpm:
        time.sleep(max(0, q[0] + 60 - now) + 0.05); return slot(key_id, rpm)
    q.append(time.time())

def payload(model, mode):
    if mode == "vision":
        msgs = [{"role": "user", "content": [
            {"type": "text", "text": "Read the traffic sign. What does it say and what color is it?"},
            {"type": "image_url", "image_url": {"url": IMG}}]}]
        p = {"model": model, "messages": msgs, "temperature": 0.6, "top_p": 0.95,
             "max_tokens": 256, "stream": False}
        if "omni" in model: p["reasoning_budget"] = 4096
        else: p["chat_template_kwargs"] = {"enable_thinking": True}
        return p
    if mode == "tools":
        return {"model": model, "messages": [{"role": "user",
                 "content": "Read the file /etc/hostname. Call the tool."}],
                "tools": TOOLS, "tool_choice": "auto", "max_tokens": 128, "stream": False}
    msgs = [{"role": "user", "content": "Write a limerick about GPU computing."}]
    p = {"model": model, "messages": msgs, "temperature": 1.0, "top_p": 0.95,
         "max_tokens": 64, "stream": mode == "stream",
         "chat_template_kwargs": {"enable_thinking": True}}
    return p

def classify(code, body):
    b = (body or "").lower()
    if code == 200: return "OK"
    if "missing request extension" in b: return "AXUM_500"
    if "resourceexhausted" in b or "worker local total" in b: return "CONC_503"
    if code == 404: return "RETIRED_404"
    if code == 429: return "RPM_429"
    if code in (401, 403): return "AUTH"
    return f"HTTP_{code}"

def run(model, api_key, key_id, mode, timeout=90):
    p = payload(model, mode); body = json.dumps(p).encode()
    hdrs = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
            "Accept": "text/event-stream" if p.get("stream") else "application/json"}
    slot(key_id)
    t0 = time.time(); out = {"verdict": "?", "ttft": None, "chunks": 0,
                             "content": "", "reasoning": "", "tool_calls": None, "usage": None, "err": ""}
    try:
        req = urllib.request.Request(URL, data=body, headers=hdrs, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if p.get("stream"):
                for raw in r:
                    line = raw.decode(errors="replace").strip()
                    if not line.startswith("data:"): continue
                    chunk = line[5:].strip()
                    if chunk == "[DONE]": out["verdict"] = "OK"; break
                    out["chunks"] += 1
                    try: d = json.loads(chunk)
                    except Exception: continue
                    if out["ttft"] is None: out["ttft"] = time.time() - t0
                    for ch in d.get("choices") or []:
                        dl = ch.get("delta") or {}
                        out["content"] += dl.get("content") or ""
                        out["reasoning"] += dl.get("reasoning_content") or ""
                    if d.get("usage"): out["usage"] = d["usage"]
                else:
                    out["verdict"] = "NO_DONE"
            else:
                txt = r.read().decode(errors="replace")
                out["verdict"] = classify(r.status, txt)
                if r.status == 200:
                    d = json.loads(txt)
                    ch = (d.get("choices") or [{}])[0]
                    msg = ch.get("message") or {}
                    out["content"] = msg.get("content") or ""
                    out["reasoning"] = msg.get("reasoning_content") or msg.get("reasoning") or ""
                    out["tool_calls"] = msg.get("tool_calls")
                    out["usage"] = d.get("usage")
                    out["ttft"] = time.time() - t0
    except urllib.error.HTTPError as e:
        t = e.read().decode(errors="replace"); out["verdict"] = classify(e.code, t); out["err"] = t[:70]
    except TimeoutError:
        out["verdict"] = "TIMEOUT_HANG"; out["err"] = f"> {timeout}s no response"
    except Exception as e:
        out["verdict"] = "EXC_" + type(e).__name__; out["err"] = str(e)[:70]
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--keys", default="1-6")
    ap.add_argument("--modes", default="text,stream,vision,tools")
    ap.add_argument("--models", default="nvidia/nemotron-3-ultra-550b-a55b,"
                                        "nvidia/nemotron-3.5-super-vl-120b-a12b,"
                                        "nvidia/nemotron-3-nano-omni-30b-a3b-reasoning")
    a = ap.parse_args(); load_env()
    lo, hi = a.keys.split("-"); keys = [f"NVIDIA_API_KEY_{i}" for i in range(int(lo), int(hi) + 1)]
    modes = a.modes.split(","); models = a.models.split(",")
    print("=" * 96)
    print(f" DIRECT NVIDIA PROBE | keys={len(keys)} models={len(models)} modes={modes}")
    print("=" * 96)
    bad = {}
    for kn in keys:
        kv = os.environ.get(kn, "")
        if not kv: print(f"⚠️ {kn} empty"); continue
        for m in models:
            for mode in modes:
                r = run(m, kv, kn, mode)
                v = r["verdict"]
                icon = "✅" if v == "OK" else ("⚠️" if v == "CONC_503" else "❌")
                ttft = f"{r['ttft']:.1f}s" if r["ttft"] else "  -  "
                extra = ""
                if mode == "stream": extra = f"chunks={r['chunks']} think={len(r['reasoning'])}c"
                if mode == "tools":
                    tc = r["tool_calls"]
                    extra = f"tool_calls={'YES:'+tc[0]['function']['name'] if tc else 'NONE'}"
                if mode == "vision": extra = (r["content"] or r["reasoning"])[:38]
                print(f" {icon} {kn:16s} {m.split('/')[-1][:34]:34s} {mode:6s} {v:12s} {ttft:>6s} {extra}")
                if v not in ("OK", "CONC_503"):
                    bad.setdefault((m, mode), []).append((kn, v, r["err"]))
            print()
    print("-" * 96)
    print("VERDICT")
    if not bad:
        print(" ✅ All probed combinations healthy.")
    for (m, mode), fails in bad.items():
        codes = sorted({f[1] for f in fails})
        print(f" ❌ {m} [{mode}] -> {','.join(codes)}")
        if mode == "tools":
            print("    ⚠️  CLAUDE CODE SENDING TOOLS MAY HANG ON THIS MODEL.")
            print("        Mitigation: point claude-haiku-5 / worker aliases at a tools-safe model,")
            print("        or add 'tools'-capability pre-check + fallback in router_settings.fallbacks.")
        if "RETIRED_404" in codes:
            print("    -> REMOVE from models/*.yaml (404 is NOT retried by retry_policy).")
    sys.exit(1 if bad else 0)

if __name__ == "__main__":
    main()
