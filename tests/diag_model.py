#!/usr/bin/env python3
"""Three-shape diagnostic for ONE model. Settles 'dead endpoint' vs
'probe asking the wrong way' — the super-vl UPSTREAM_500 question.

Shapes tried, in order (stop at first OK):
  minimal     : stream=false, max_tokens=8, no extras   <- what probe_live_endpoints used
  think_ns    : stream=false, max_tokens=64, enable_thinking=true
  think_sse   : stream=true,  max_tokens=64, enable_thinking=true   <- Claude Code's real shape

Verdicts per key:
  OK                minimal works
  OK_THINK_REQUIRED needs enable_thinking, non-stream fine
  OK_STREAM_ONLY    only SSE works  -> FINE for Claude Code (it always streams)
  FLAKE_RECOVERED   failed all shapes, passed minimal on 4s retry -> transient
  DEAD              all shapes, all keys failed -> retire it

Usage:
  python3 tests/diag_model.py nvidia/nemotron-3.5-super-vl-120b-a12b --keys 1-3
"""
import json, os, sys, time, argparse, urllib.request, urllib.error

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
URL = "https://integrate.api.nvidia.com/v1/chat/completions"


def load_env():
    p = os.path.join(BASE, ".env")
    if not os.path.exists(p):
        sys.exit(f"❌ .env not found at {p}")
    data = open(p, "rb").read().decode("utf-8-sig", "replace").replace("\r\n", "\n").replace("\r", "\n")
    for line in data.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip().strip('"'))


def classify(code, body):
    b = (body or "").lower()
    if code == 200: return "OK"
    if "missing request extension" in b: return "AXUM_500"
    if "resourceexhausted" in b or "worker local total" in b: return "CONC_503"
    if code == 404: return "RETIRED_404"
    if code == 429: return "RPM_429"
    if code in (401, 403): return "AUTH"
    if code in (500, 502, 504): return f"UPSTREAM_{code}"
    return f"HTTP_{code}"


def _shape(model, name):
    msgs = [{"role": "user", "content": "Reply with the single word: ok"}]
    if name == "minimal":
        return {"model": model, "messages": msgs, "max_tokens": 8, "stream": False}
    if name == "think_ns":
        return {"model": model, "messages": msgs, "max_tokens": 64, "stream": False,
                "chat_template_kwargs": {"enable_thinking": True}}
    if name == "think_sse":
        return {"model": model, "messages": msgs, "max_tokens": 64, "stream": True,
                "chat_template_kwargs": {"enable_thinking": True}}
    raise ValueError(name)


def _sse_got_tokens(r):
    """True if the SSE stream carried real output (delta text or usage or [DONE])."""
    for raw in r:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        chunk = line[5:].strip()
        if chunk == "[DONE]":
            return True
        try:
            d = json.loads(chunk)
        except Exception:
            continue
        if d.get("usage"):
            return True
        for ch in d.get("choices") or []:
            delta = ch.get("delta") or {}
            if delta.get("content") or delta.get("reasoning_content") or delta.get("tool_calls"):
                return True
    return False


def run_shape(model, api_key, shape, timeout=60):
    p = _shape(model, shape)
    body = json.dumps(p).encode()
    hdrs = {"Authorization": f"Bearer {api_key}", "Content-Type": "application/json",
            "Accept": "text/event-stream" if p.get("stream") else "application/json"}
    t0 = time.time()
    try:
        req = urllib.request.Request(URL, data=body, headers=hdrs, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if p.get("stream"):
                ok = _sse_got_tokens(r)
                return ("OK" if ok else "EMPTY_STREAM", time.time() - t0, "")
            txt = r.read().decode("utf-8", "replace")
            return (classify(r.status, txt), time.time() - t0,
                    "" if r.status == 200 else txt[:80])
    except urllib.error.HTTPError as e:
        t = e.read().decode("utf-8", "replace")
        return (classify(e.code, t), time.time() - t0, t[:80])
    except Exception as e:
        return ("EXC_" + type(e).__name__, time.time() - t0, str(e)[:80])


def verdict_for_key(model, api_key, timeout=60, retry=True):
    """Returns (verdict, {shape: (v, lat, detail)})."""
    res = {}
    for shape in ("minimal", "think_ns", "think_sse"):
        v, lat, det = run_shape(model, api_key, shape, timeout)
        res[shape] = (v, lat, det)
        if v == "OK":
            return {"minimal": "OK", "think_ns": "OK_THINK_REQUIRED",
                    "think_sse": "OK_STREAM_ONLY"}[shape], res
    if retry:
        time.sleep(4)
        v, lat, det = run_shape(model, api_key, "minimal", timeout)
        res["minimal#retry"] = (v, lat, det)
        if v == "OK":
            return "FLAKE_RECOVERED", res
    return "DEAD", res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model", help="e.g. nvidia/nemotron-3.5-super-vl-120b-a12b")
    ap.add_argument("--keys", default="1-3")
    ap.add_argument("--timeout", type=int, default=60)
    a = ap.parse_args()
    load_env()
    lo, hi = a.keys.split("-")
    keys = [f"NVIDIA_API_KEY_{i}" for i in range(int(lo), int(hi) + 1)]

    print(f"DIAG {a.model}  keys={len(keys)}")
    print("=" * 78)
    verdicts = {}
    for kn in keys:
        kv = os.environ.get(kn, "")
        if not kv:
            print(f"  ⚠️  {kn} empty"); continue
        verd, res = verdict_for_key(a.model, kv, a.timeout)
        verdicts[kn] = verd
        shapes = " | ".join(f"{s}={v}({lat:.1f}s)" for s, (v, lat, _) in res.items())
        icon = {"OK": "✅", "OK_THINK_REQUIRED": "✅", "OK_STREAM_ONLY": "🟢",
                "FLAKE_RECOVERED": "⚠️", "DEAD": "❌"}[verd]
        print(f"  {icon} {kn:16s} {verd:18s} {shapes}")
        for s, (v, _, det) in res.items():
            if v != "OK" and det:
                print(f"      {s}: {det}")
    print("=" * 78)
    alive = [k for k, v in verdicts.items() if v != "DEAD"]
    if not alive:
        print("❌ DEAD on all keys tested -> retire it (see Case B kit)")
        sys.exit(1)
    stream_only = all(v in ("OK_STREAM_ONLY", "FLAKE_RECOVERED") for v in verdicts.values() if v != "DEAD")
    if stream_only:
        print("🟢 ALIVE (SSE-only). Claude Code always streams -> SAFE TO KEEP.")
        print("   probe_live_endpoints will now report OK_STREAM_ONLY, not a failure.")
    else:
        print(f"✅ ALIVE on: {', '.join(alive)}")
    sys.exit(0)


if __name__ == "__main__":
    main()
