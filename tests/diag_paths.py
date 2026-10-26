#!/usr/bin/env python3
"""Path + shape matrix diagnostic. Answers the two questions still open:

  Q1  Is /v1/messages (the ONLY API Claude Code speaks) actually working?
      Everything verified so far was /v1/chat/completions. Different LiteLLM
      code path (Anthropic->OpenAI translator). Untested until now.

  Q2  What is the REAL non-stream 400 body? probe_proxy sliced it to 28 chars
      ("Invalid request format: 'fun") so we have never seen it.

Also separates nginx from LiteLLM-direct, so a 400 can be attributed.

  python3 tests/diag_paths.py                 # nginx, full matrix
  python3 tests/diag_paths.py --direct        # LiteLLM only (bypass nginx)
  python3 tests/diag_paths.py --only msgs     # just the Claude Code path
"""
import json, os, sys, time, argparse, urllib.request, urllib.error

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMG = "https://assets.ngc.nvidia.com/products/api-catalog/phi-3-5-vision/example1b.jpg"

OPENAI_TOOLS = [{"type": "function", "function": {
    "name": "read_file", "description": "Read a file from disk",
    "parameters": {"type": "object", "properties": {"path": {"type": "string"}},
                   "required": ["path"]}}}]
ANTH_TOOLS = [{"name": "read_file", "description": "Read a file from disk",
               "input_schema": {"type": "object",
                                "properties": {"path": {"type": "string"}},
                                "required": ["path"]}}]


def load_env():
    p = os.path.join(BASE, ".env")
    raw = open(p, "rb").read().decode("utf-8-sig", "replace")
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip()
        if len(v) > 1 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        os.environ.setdefault(k.strip(), v)
    mk = os.environ.get("LITELLM_MASTER_KEY", "")
    if not mk:
        sys.exit("❌ LITELLM_MASTER_KEY empty. Run: source tests/env.sh")
    return mk


def base_urls(direct):
    np = open(os.path.join(BASE, ".nginx_port")).read().strip()
    lp = open(os.path.join(BASE, ".litellm_port")).read().strip()
    host = f"127.0.0.1:{lp}" if direct else f"127.0.0.1:{np}"
    return f"http://{host}", ("litellm-direct" if direct else "nginx")


def post(url, mk, body, stream, anthropic, timeout=90):
    hdrs = {"Authorization": f"Bearer {mk}", "Content-Type": "application/json",
            "Accept": "text/event-stream" if stream else "application/json"}
    if anthropic:
        hdrs = {"x-api-key": mk, "anthropic-version": "2023-06-01",
                "Content-Type": "application/json",
                "Accept": "text/event-stream" if stream else "application/json"}
    t0 = time.time()
    out = {"code": 0, "text": "", "think": "", "tools": None, "stop": None,
           "chunks": 0, "terminal": False, "err": "", "lat": 0.0}
    try:
        req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                     headers=hdrs, method="POST")
        with urllib.request.urlopen(req, timeout=timeout) as r:
            out["code"] = r.status
            if stream:
                cur_event = ""
                for raw in r:
                    line = raw.decode("utf-8", "replace").rstrip("\n").strip()
                    if line.startswith("event:"):
                        cur_event = line[6:].strip(); continue
                    if not line.startswith("data:"):
                        continue
                    payload = line[5:].strip()
                    if payload == "[DONE]":
                        out["terminal"] = True; break
                    out["chunks"] += 1
                    try:
                        d = json.loads(payload)
                    except Exception:
                        continue
                    if anthropic:
                        if d.get("type") == "message_stop":
                            out["terminal"] = True
                        if d.get("type") == "message_delta":
                            out["stop"] = (d.get("delta") or {}).get("stop_reason")
                        blk = d.get("content_block") or {}
                        if blk.get("type") == "tool_use":
                            out["tools"] = (out["tools"] or []) + [
                                {"name": blk.get("name"), "input": blk.get("input")}]
                        dl = d.get("delta") or {}
                        if dl.get("type") == "text_delta":
                            out["text"] += dl.get("text") or ""
                        elif dl.get("type") == "thinking_delta":
                            out["think"] += dl.get("thinking") or ""
                        elif dl.get("type") == "input_json_delta":
                            if out["tools"]:
                                out["tools"][-1]["input_raw"] = \
                                    out["tools"][-1].get("input_raw", "") + (dl.get("partial_json") or "")
                    else:
                        for ch in d.get("choices") or []:
                            delta = ch.get("delta") or {}
                            out["text"] += delta.get("content") or ""
                            out["think"] += delta.get("reasoning_content") or ""
                            for tc in delta.get("tool_calls") or []:
                                i = tc.get("index", 0)
                                s = (out["tools"] or {}).get(i) if isinstance(out["tools"], dict) else None
                                if not isinstance(out["tools"], dict):
                                    out["tools"] = {}
                                s = out["tools"].setdefault(i, {"name": "", "args": ""})
                                f = tc.get("function") or {}
                                s["name"] += f.get("name") or ""
                                s["args"] += f.get("arguments") or ""
                            if ch.get("finish_reason"):
                                out["stop"] = ch["finish_reason"]; out["terminal"] = True
            else:
                txt = r.read().decode("utf-8", "replace")
                try:
                    d = json.loads(txt)
                except Exception:
                    out["err"] = txt; return out
                if anthropic:
                    for b in d.get("content") or []:
                        if b.get("type") == "text":
                            out["text"] += b.get("text") or ""
                        elif b.get("type") == "thinking":
                            out["think"] += b.get("thinking") or ""
                        elif b.get("type") == "tool_use":
                            out["tools"] = (out["tools"] or []) + [
                                {"name": b.get("name"), "input": b.get("input")}]
                    out["stop"] = d.get("stop_reason")
                else:
                    msg = ((d.get("choices") or [{}])[0]).get("message") or {}
                    out["text"] = msg.get("content") or ""
                    out["think"] = msg.get("reasoning_content") or msg.get("reasoning") or ""
                    out["tools"] = msg.get("tool_calls")
                    out["stop"] = (d.get("choices") or [{}])[0].get("finish_reason")
                out["terminal"] = True
    except urllib.error.HTTPError as e:
        out["code"] = e.code
        out["err"] = e.read().decode("utf-8", "replace")
    except Exception as e:
        out["code"] = 0
        out["err"] = f"EXC {type(e).__name__}: {e}"
    out["lat"] = time.time() - t0
    return out


# ---------------- shape builders ----------------
def chat_shapes(alias, stream):
    m = [{"role": "user", "content": "Reply with the single word: ok"}]
    yield "bare",    {"model": alias, "messages": m, "max_tokens": 16, "stream": stream}
    yield "+temp",   {"model": alias, "messages": m, "max_tokens": 16, "stream": stream,
                      "temperature": 1.0, "top_p": 0.95}
    yield "+think",  {"model": alias, "messages": m, "max_tokens": 64, "stream": stream,
                      "temperature": 1.0, "top_p": 0.95,
                      "chat_template_kwargs": {"enable_thinking": True}}
    yield "+tools",  {"model": alias, "messages": [{"role": "user",
                          "content": "Read /etc/hostname using the tool."}],
                      "max_tokens": 200, "stream": stream,
                      "chat_template_kwargs": {"enable_thinking": True},
                      "tools": OPENAI_TOOLS, "tool_choice": "auto"}


def msgs_shapes(alias, stream):
    m = [{"role": "user", "content": "say hi"}]
    yield "bare",    {"model": alias, "max_tokens": 32, "messages": m, "stream": stream}
    yield "+system", {"model": alias, "max_tokens": 32, "stream": stream,
                      "system": "You are terse. Reply with one word.", "messages": m}
    yield "+think",  {"model": alias, "max_tokens": 200, "stream": stream,
                      "system": "You are terse.",
                      "messages": [{"role": "user", "content": "Count 1 to 5."}]}
    yield "cc-real", {"model": alias, "max_tokens": 128, "stream": stream,
                      "system": ("You are Claude Code, an interactive agent that helps users "
                                 "with software engineering tasks. Use tools when asked."),
                      "messages": [{"role": "user",
                                    "content": "Read the file /etc/hostname and tell me its contents."}],
                      "tools": ANTH_TOOLS + [
                          {"name": "bash", "description": "Run a shell command",
                           "input_schema": {"type": "object",
                                            "properties": {"command": {"type": "string"}},
                                            "required": ["command"]}}],
                      "tool_choice": {"type": "auto"}}


def show(tag, o, anthropic):
    got = (o["text"] or o["think"])
    ok = o["code"] == 200 and bool(got) and o["terminal"]
    icon = "✅" if ok else "❌"
    tl = ""
    if isinstance(o["tools"], dict):
        tl = " tools=" + ",".join(v["name"] for v in o["tools"].values() if v["name"])
    elif isinstance(o["tools"], list) and o["tools"]:
        tl = " tools=" + ",".join(t.get("name", "?") for t in o["tools"])
    print(f" {icon} {tag:26s} HTTP {o['code']:3d} {o['lat']:5.1f}s "
          f"chunks={o['chunks']:3d} stop={str(o['stop']):10s} "
          f"txt={len(o['text']):4d} think={len(o['think']):4d}{tl}")
    if not ok:
        # FULL BODY — the entire reason this file exists
        body = o["err"] or json.dumps({"note": "200 but no usable output",
                                       "text": o["text"][:200], "terminal": o["terminal"]})
        print("      ┌─ FULL RESPONSE BODY (untruncated) ─────────────────────────")
        for ln in body[:4000].splitlines() or ["(empty)"]:
            print("      │ " + ln[:150])
        print("      └─────────────────────────────────────────────────────────────")
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--alias", default="claude-opus-5")
    ap.add_argument("--direct", action="store_true", help="bypass nginx, hit LiteLLM")
    ap.add_argument("--only", choices=["chat", "msgs"], default=None)
    a = ap.parse_args()
    mk = load_env()
    root, via = base_urls(a.direct)
    print(f"VIA={via}  alias={a.alias}  master={len(mk)} chars\n" + "=" * 96)

    results = {}
    matrix = []
    if a.only != "msgs":
        matrix += [("chat", s, chat_shapes(a.alias, s)) for s in (False, True)]
    if a.only != "chat":
        matrix += [("msgs", s, msgs_shapes(a.alias, s)) for s in (False, True)]

    for api, stream, shapes in matrix:
        path = "/v1/chat/completions" if api == "chat" else "/v1/messages"
        print(f"\n── {path}  stream={stream} ──")
        for name, body in shapes:
            o = post(root + path, mk, body, stream, api == "msgs")
            results[(api, stream, name)] = show(f"{api}/{name}", o, api == "msgs")
            time.sleep(0.4)

    print("\n" + "=" * 96)
    print("SUMMARY")
    for api in ("chat", "msgs"):
        for stream in (False, True):
            row = {n: r for (aa, ss, n), r in results.items() if aa == api and ss == stream}
            if not row:
                continue
            allok = all(row.values())
            print(f"  {'✅' if allok else '❌'} /v1/{'chat/completions' if api=='chat' else 'messages':19s}"
                  f" stream={str(stream):5s} " +
                  "  ".join(f"{n}:{'OK' if v else 'FAIL'}" for n, v in row.items()))

    cc = all(v for (api, st, n), v in results.items() if api == "msgs" and st)
    print("\n" + "-" * 96)
    if cc:
        print("🟢 /v1/messages STREAMS CORRECTLY -> Claude Code's real path is healthy.")
        ns = all(v for (api, st, n), v in results.items() if api == "msgs" and not st)
        if not ns:
            print("   ⚠️  /v1/messages NON-STREAM failed. Claude Code uses non-streaming for")
            print("       auxiliary calls (session titles, compaction summaries). Those will")
            print("       error until the body above is explained. Not fatal for main turns.")
    else:
        print("🔴 /v1/messages IS BROKEN. Claude Code cannot work, regardless of how green")
        print("    /v1/chat/completions is. Paste the FULL BODY block above — it names the")
        print("    offending field, and the fix is in LiteLLM's anthropic translation layer")
        print("    (config_base.yaml), not in the scenes.")
    sys.exit(0 if cc else 1)


if __name__ == "__main__":
    main()
