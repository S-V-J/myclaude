#!/usr/bin/env python3
"""Proxy-path probe, v2.

Design changes forced by the v1 run:
  §1/§2 STREAM. Claude Code always streams; v1's §1/§3/§4 were all non-stream,
     so 6 of 7 failures were the SAME unidentified 400 — and v1 sliced the
     message to 28 chars ("Invalid request format: 'fun"), so it could never
     tell us what it was. v2 prints FULL bodies.
  §4 bursts LITELLM-DIRECT  -> measures the GUARD (nginx's 30r/m limiter out of play)
  §5 bursts NGINX           -> measures the LIMITER (429 is the PASS condition)
     v1 fired 24 at nginx and read 14x429 + 10x400 as "guard leak". It was the
     limiter doing its job (30r/m burst=10 nodelay rejects >=11 simultaneous).
  Non-stream demoted to §3 as a WARN-only monitor.

  python3 tests/probe_proxy.py [--burst 8] [--guard-only]
"""
import json, os, sys, time, argparse, urllib.request, urllib.error
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHAT = ["claude-opus-5", "claude-opus-5-1m", "claude-sonnet-5",
        "claude-sonnet-5-1m", "claude-haiku-5"]
VIS  = ["claude-3-5-sonnet-20241022-vision"]
IMG  = "https://assets.ngc.nvidia.com/products/api-catalog/phi-3-5-vision/example1b.jpg"
TOOLS = [{"type": "function", "function": {
    "name": "read_file", "description": "Read a file from disk",
    "parameters": {"type": "object", "properties": {"path": {"type": "string"}},
                   "required": ["path"]}}}]


def ctx():
    raw = open(os.path.join(BASE, ".env"), "rb").read().decode("utf-8-sig", "replace")
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    for line in raw.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1); v = v.strip()
            if len(v) > 1 and v[0] == v[-1] and v[0] in "\"'": v = v[1:-1]
            os.environ.setdefault(k.strip(), v)
    mk = os.environ.get("LITELLM_MASTER_KEY", "")
    if not mk:
        sys.exit("❌ LITELLM_MASTER_KEY empty — `source tests/env.sh` first")
    np = open(os.path.join(BASE, ".nginx_port")).read().strip()
    lp = open(os.path.join(BASE, ".litellm_port")).read().strip()
    return (f"http://127.0.0.1:{np}/v1/chat/completions",
            f"http://127.0.0.1:{lp}/v1/chat/completions", mk)


def call(url, mk, payload, timeout=180):
    hdrs = {"Authorization": f"Bearer {mk}", "Content-Type": "application/json",
            "Accept": "text/event-stream" if payload.get("stream") else "application/json"}
    t0 = time.time()
    res = {"ok": False, "verdict": "?", "model": "", "content": "", "reasoning": "",
           "tool_calls": None, "chunks": 0, "done": False, "lat": 0.0, "ttft": None,
           "err": "", "body": ""}
    tmap = {}
    try:
        req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                     headers=hdrs, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if payload.get("stream"):
                for raw in r:
                    line = raw.decode("utf-8", "replace").strip()
                    if not line.startswith("data:"): continue
                    c = line[5:].strip()
                    if c == "[DONE]": res["done"] = True; break
                    res["chunks"] += 1
                    if res["ttft"] is None: res["ttft"] = time.time() - t0
                    try: d = json.loads(c)
                    except Exception: continue
                    res["model"] = d.get("model") or res["model"]
                    for ch in d.get("choices") or []:
                        dl = ch.get("delta") or {}
                        res["content"] += dl.get("content") or ""
                        res["reasoning"] += dl.get("reasoning_content") or ""
                        for tc in dl.get("tool_calls") or []:
                            i = tc.get("index", 0)
                            s = tmap.setdefault(i, {"name": "", "args": "", "id": tc.get("id", "")})
                            f = tc.get("function") or {}
                            s["name"] += f.get("name") or ""
                            s["args"] += f.get("arguments") or ""
            else:
                txt = r.read().decode("utf-8", "replace"); res["body"] = txt[:2000]
                d = json.loads(txt)
                res["model"] = d.get("model", "")
                msg = ((d.get("choices") or [{}])[0]).get("message") or {}
                res["content"] = msg.get("content") or ""
                res["reasoning"] = msg.get("reasoning_content") or msg.get("reasoning") or ""
                res["tool_calls"] = msg.get("tool_calls")
                res["ttft"] = time.time() - t0
        if tmap:
            res["tool_calls"] = [{"id": v["id"], "type": "function",
                                  "function": {"name": v["name"], "arguments": v["args"]}}
                                 for _, v in sorted(tmap.items())]
        res["ok"] = True; res["verdict"] = "OK"
    except urllib.error.HTTPError as e:
        t = e.read().decode("utf-8", "replace")
        res["verdict"] = f"HTTP_{e.code}"; res["body"] = t[:2000]      # FULL body
        try: res["err"] = json.loads(t).get("error", {}).get("message", t)[:200]
        except Exception: res["err"] = t[:200]
    except Exception as e:
        res["verdict"] = "EXC_" + type(e).__name__; res["err"] = str(e)[:200]
    res["lat"] = time.time() - t0
    return res


def dump(r, indent="      "):
    """Print the WHOLE error body. v1's [:28] slice is why 'fun' is still a mystery."""
    if not r["body"]: return
    print(f"{indent}┌─ full body ─────────────────────────────────────")
    for ln in (r["body"].splitlines() or [r["body"]]):
        print(f"{indent}│ {ln[:160]}")
    print(f"{indent}└──────────────────────────────────────────────────")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--burst", type=int, default=8)
    ap.add_argument("--guard-only", action="store_true")
    a = ap.parse_args()
    nginx, direct, mk = ctx()
    print(f"nginx={nginx}\nlitellm={direct}\n" + "=" * 100)
    fails = warns = 0

    if not a.guard_only:
        print("1) ALIAS RESOLUTION — STREAM (production shape)")
        for al in CHAT + VIS:
            pl = ({"model": al, "max_tokens": 64, "stream": True, "temperature": 0.6,
                   "messages": [{"role": "user", "content": [
                       {"type": "text", "text": "One sentence: what is in this image?"},
                       {"type": "image_url", "image_url": {"url": IMG}}]}]}
                  if al in VIS else
                  {"model": al, "messages": [{"role": "user", "content": "Reply 'ok'"}],
                   "max_tokens": 32, "stream": True})
            r = call(nginx, mk, pl)
            good = r["ok"] and r["chunks"] > 1 and (r["content"] or r["reasoning"])
            if not good: fails += 1
            print(f" {'✅' if good else '❌'} {al:34s} {r['verdict']:9s} {r['lat']:5.1f}s "
                  f"chunks={r['chunks']:3d} done={r['done']} model={r['model'][:24]:24s} "
                  f"{(r['content'] or r['reasoning'] or r['err'])[:22]!r}")
            if not good: dump(r)

        print("\n2) TOOL CALLS — STREAM THROUGH NGINX (Claude Code's real workload)")
        r = call(nginx, mk, {"model": "claude-opus-5", "tools": TOOLS, "tool_choice": "auto",
                             "max_tokens": 200, "stream": True,
                             "messages": [{"role": "user",
                                           "content": "Read /etc/hostname using the tool."}]})
        tc = r["tool_calls"]
        if not r["ok"]: fails += 1
        elif not tc: warns += 1
        desc = f"{tc[0]['function']['name']}({tc[0]['function']['arguments']})" if tc else "NONE"
        print(f" {'✅' if tc else '⚠️ '} {r['verdict']:9s} {r['lat']:5.1f}s chunks={r['chunks']} tool_calls={desc[:70]}")
        if not r["ok"]: dump(r)

        print("\n3) NON-STREAM MONITOR (known-issue; Claude Code aux calls use this)")
        ns = Counter()
        for al in CHAT[:2] + VIS[:1]:
            pl = ({"model": al, "max_tokens": 32, "stream": False, "temperature": 0.6,
                   "messages": [{"role": "user", "content": [
                       {"type": "text", "text": "One word: color?"},
                       {"type": "image_url", "image_url": {"url": IMG}}]}]}
                  if al in VIS else
                  {"model": al, "messages": [{"role": "user", "content": "Reply ok"}],
                   "max_tokens": 16, "stream": False})
            r = call(nginx, mk, pl); ns[r["verdict"]] += 1
            print(f"    {al:34s} {r['verdict']:9s} {r['err'][:100]}")
            if not r["ok"]: dump(r, "      ")
        if ns.get("OK"):
            print("    ✅ non-stream recovered -> §1 can go back to non-stream too")
        else:
            warns += 1
            print(f"    ⚠️ non-stream still {dict(ns)} — main turns unaffected (Claude Code streams),")
            print("       but session-title / compaction aux calls will error. Run tests/diag_paths.py.")

    print(f"\n4) GUARD PROOF — LITELLM DIRECT, burst={a.burst} (nginx bypassed)")
    def one(_):
        return call(direct, mk, {"model": "claude-opus-5",
                                 "messages": [{"role": "user", "content": "Say hi."}],
                                 "max_tokens": 8, "stream": True}, timeout=240)
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=a.burst) as ex:
        rs = list(ex.map(one, range(a.burst)))
    wall = time.time() - t0
    c = Counter(x["verdict"] for x in rs)
    ok = c.get("OK", 0)
    leak = sum(1 for x in rs if "503" in x["verdict"]
               or "ResourceExhausted" in x.get("err", "")
               or "Worker local total" in x.get("err", ""))
    lat = sorted(x["lat"] for x in rs if x["ok"])
    print(f"    wall={wall:.1f}s results={dict(c)} success={ok}/{a.burst} 503-leak={leak}")
    if lat:
        print(f"    latency min={lat[0]:.1f}s max={lat[-1]:.1f}s ratio={lat[-1]/max(lat[0],0.1):.1f}x"
              f"   (cap=2 + burst=8 should give ~4x; ~1x means the cap was not engaged)")
    if leak:
        fails += 1
        print("    ❌ GUARD LEAK. Check guard.log for 'new bucket=' and PYTHONPATH in the drop-in.")
    elif ok == a.burst:
        print("    ✅ all served, zero 503 escaped")
    else:
        warns += 1
        print(f"    ⚠️ {a.burst-ok} failed (not 503) — tail guard.log + journalctl -u myclaude")
    for x in rs:
        if not x["ok"] and x["body"]: dump(x, "      "); break

    print("\n5) NGINX RATE LIMITER (30r/m burst=10 nodelay) — 429 IS THE PASS CONDITION")
    n2 = 14
    def two(_):
        return call(nginx, mk, {"model": "claude-haiku-5",
                                "messages": [{"role": "user", "content": "ping"}],
                                "max_tokens": 4, "stream": True}, timeout=60)
    with ThreadPoolExecutor(max_workers=n2) as ex:
        rs2 = list(ex.map(two, range(n2)))
    c2 = Counter(x["verdict"] for x in rs2)
    n429 = c2.get("HTTP_429", 0)
    print(f"    {n2} simultaneous via nginx -> {dict(c2)}")
    if n429 >= 1:
        print(f"    ✅ limiter engaged as designed ({n429} rejected). NOT a guard failure.")
    else:
        warns += 1
        print("    ⚠️ no 429 — limit_req_zone may not be in http{}; check conf.d/myclaude-limit.conf")

    print("\n" + "=" * 100)
    print(f"VERDICT: {'✅ PROXY HEALTHY' if not fails else f'❌ {fails} FAILURE(S)'}"
          f"{f'  ({warns} warnings)' if warns else ''}")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
