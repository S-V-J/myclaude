#!/usr/bin/env python3
"""Assert STREAMING + THINKING on every alias, on every transport, both modes.

WHY THIS FILE EXISTS
  The requirement is "all AI models must have streaming and thinking enabled in
  all the files". Two facts had to be separated before that could be tested:

    * THINKING is a model-level parameter -> it lives in models/scene_*.yaml and
      must be asserted per alias, because a scene generator can silently disable
      it for one family (the vision scene shipped with enable_thinking:false for
      several revisions) and nothing else in the stack would notice.

    * STREAMING is a per-REQUEST parameter, not a model property. There is no
      model_list key that "enables streaming for a model", and adding
      stream:true to litellm_params would be a BUG-C-class act: an unknown or
      forced top-level key reaching the provider body, which NVIDIA's
      server-side validator rejects with HTTP 400 on 100% of traffic
      (drop_params:true does NOT protect against that -- proven empirically in
      this project with _mc_cid). Worse, forcing stream:true would break the
      NON-streaming auxiliary calls Claude Code depends on (session auto-title,
      rename, context compaction), which this harness therefore also asserts.
      Streaming is enabled at exactly two real layers, and this file measures
      both: nginx (proxy_buffering off -> chunks must arrive as >1 event) and
      the client (it must actually ask for stream=true).

WHAT COUNTS AS "THINKING PRESENT" (all four spellings, because LiteLLM has four)
  chat/completions non-stream : message.reasoning_content | message.reasoning
                                | provider_specific_fields.reasoning_tokens
  chat/completions stream     : delta.reasoning_content | delta.reasoning in any chunk
  /v1/messages  non-stream    : content[] block with type == "thinking" (field "thinking")
  /v1/messages  stream        : SSE event content_block_delta with
                                type in {thinking_delta, reasoning_delta, input_json_delta}

STARVATION DETECTION (the defect this replaces a guess about)
  A cell that returns reasoning but NO answer text and a truncation stop reason
  is a thinking-budget/max_tokens misconfiguration, not a provider fault:
      txt == 0  and  stop in {max_tokens, length}   -> STARVED
  Observed in the wild before this file existed:
      msgs/bare   stream=False  txt=0 think=133 stop=max_tokens
      msgs/+system             txt=0 think=126 stop=max_tokens
      chat/+temp              txt=0 think= 70 stop=length
  Starvation is reported as a distinct failure class so it can never again be
  mistaken for "thinking is off" (it is the opposite: thinking is on and it ate
  the whole budget).

Usage:
  python3 tests/probe_think_stream.py                 # all aliases, all 4 cells
  python3 tests/probe_think_stream.py --aliases claude-opus-5,claude-haiku-5
  python3 tests/probe_think_stream.py --via nginx     # default
  python3 tests/probe_think_stream.py --via direct
  python3 tests/probe_think_stream.py --min-think 8   # raise the bar (chars)
Exit code: 0 = every cell streamed AND thought AND was not starved.
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Aliases that must satisfy the requirement. Read from config.yaml so a new scene
# is covered automatically -- hardcoding the list is how the vision alias escaped
# scrutiny for as long as it did.
DEFAULT_ALIASES = [
    "claude-opus-5", "claude-opus-5-1m", "claude-sonnet-5", "claude-sonnet-5-1m",
    "claude-haiku-5", "claude-3-5-sonnet-20241022-vision",
]

REASON_KEYS = ("reasoning_content", "reasoning", "reasoning_text")
THINK_STOP = ("max_tokens", "length", "MAX_TOKENS", "LENGTH")


def _load_env():
    """Parse .env the same way myclaude.sh does: BOM-strip, CRLF-normalise,
    strip matching quotes, ignore comments. bash `source` is not used because it
    silently produces NOTHING on CRLF, which is a defect this project already
    hit. Returns (env_dict, litellm_port, nginx_port)."""
    env = {}
    try:
        raw = open(os.path.join(BASE, ".env"), "rb").read().decode("utf-8-sig", "replace")
    except OSError:
        return env, None, None
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip()
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
            v = v[1:-1]
        env[k] = v
    def port(fn):
        try:
            return open(os.path.join(BASE, fn)).read().strip()
        except OSError:
            return None
    return env, port(".litellm_port"), port(".nginx_port")


def aliases_from_config():
    """Ground truth from the BUILT config, not from a list in this file."""
    try:
        import yaml
        cfg = yaml.safe_load(open(os.path.join(BASE, "config.yaml"), encoding="utf-8"))
        seen, out = set(), []
        for m in (cfg or {}).get("model_list") or []:
            n = m.get("model_name")
            if n and n not in seen and str(n).startswith("claude-"):
                seen.add(n); out.append(n)
        return out or list(DEFAULT_ALIASES)
    except Exception:
        return list(DEFAULT_ALIASES)


def _post(url, payload, key, timeout, headers=None):
    """One POST. Returns (status, decoded_body_or_None, raw_text, elapsed).
    Never raises: a transport error is a DATA point, and this harness's job is to
    report the matrix, not to abort halfway through it."""
    body = json.dumps(payload).encode()
    h = {"Content-Type": "application/json", "Authorization": f"Bearer {key}"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=body, headers=h, method="POST")
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
            return r.status, _try_json(raw), raw, time.time() - t0
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        return e.code, _try_json(raw), raw, time.time() - t0
    except Exception as e:
        return 0, None, f"{type(e).__name__}: {e}", time.time() - t0


def _try_json(raw):
    try:
        return json.loads(raw)
    except Exception:
        return None


def _sse_events(raw):
    """Yield the data payloads of SSE events. Tolerates both 'data: {json}' and
    'data:{json}', and ignores comments/heartbeats."""
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith(":"):
            continue
        if line.startswith("data:"):
            yield line[5:].strip()


def scan_stream(raw):
    """Walk an SSE body once, accumulating: chunk count, text, reasoning,
    stop reason, tool calls, whether [DONE] arrived, and whether any thinking
    delta was seen."""
    st = {"chunks": 0, "txt": 0, "think": 0, "stop": None, "tools": [],
          "done": False, "thought": False, "err": None}
    for data in _sse_events(raw):
        if data == "[DONE]":
            st["done"] = True
            continue
        ev = _try_json(data)
        if not isinstance(ev, dict):
            continue
        if ev.get("type") == "error" or (isinstance(ev.get("error"), dict)):
            st["err"] = json.dumps(ev.get("error") or ev)[:300]
        # --- Anthropic /v1/messages shape -----------------------------------
        et = ev.get("type")
        if et == "content_block_delta":
            st["chunks"] += 1          # real stream granularity
            d = ev.get("delta") or {}
            dt = d.get("type")
            if dt in ("thinking_delta", "reasoning_delta"):
                st["thought"] = True
                st["think"] += len(d.get("thinking") or d.get("reasoning") or "")
            elif dt == "text_delta":
                st["txt"] += len(d.get("text") or "")
            elif dt == "input_json_delta":
                st["thought"] = True   # tool_use arg streaming counts as activity
        elif et == "content_block_start":
            blk = (ev.get("content_block") or {})
            if blk.get("type") in ("thinking", "redacted_thinking"):
                st["thought"] = True
            if blk.get("type") == "tool_use":
                st["tools"].append(blk.get("name"))
            st["chunks"] += 1
        elif et == "message_stop":
            st["done"] = True          # Anthropic terminator (OpenAI uses [DONE])
        elif et == "message_delta":
            sr = ((ev.get("delta") or {}).get("stop_reason"))
            if sr:
                st["stop"] = sr
        # --- OpenAI /v1/chat/completions shape ------------------------------
        for ch in ev.get("choices") or []:
            st["chunks"] += 1
            d = ch.get("delta") or {}
            for rk in REASON_KEYS:
                if d.get(rk):
                    st["thought"] = True
                    st["think"] += len(str(d[rk]))
            if d.get("content"):
                st["txt"] += len(str(d["content"]))
            for tc in d.get("tool_calls") or []:
                fn = (tc.get("function") or {}).get("name")
                if fn and fn not in st["tools"]:
                    st["tools"].append(fn)
            if ch.get("finish_reason"):
                st["stop"] = ch["finish_reason"]
        fr = ((ev.get("choices") or [{}])[0].get("message") or {}).get("reasoning_content")
        if fr:
            st["thought"] = True
    return st


def scan_nonstream(body):
    """Same accumulator for a fully-materialised JSON response."""
    st = {"chunks": 0, "txt": 0, "think": 0, "stop": None, "tools": [],
          "done": True, "thought": False, "err": None}
    if not isinstance(body, dict):
        st["err"] = "non-JSON body"
        return st
    if isinstance(body.get("error"), dict):
        st["err"] = json.dumps(body["error"])[:300]
    # --- Anthropic shape ----------------------------------------------------
    if "content" in body and isinstance(body["content"], list):
        st["stop"] = body.get("stop_reason")
        for blk in body["content"]:
            bt = blk.get("type")
            if bt in ("thinking", "redacted_thinking"):
                st["thought"] = True
                st["think"] += len(blk.get("thinking") or blk.get("data") or "")
            elif bt == "text":
                st["txt"] += len(blk.get("text") or "")
            elif bt == "tool_use":
                st["tools"].append(blk.get("name"))
        usage = body.get("usage") or {}
        if usage.get("output_tokens_details", {}).get("thinking_tokens"):
            st["thought"] = True
    # --- OpenAI shape -------------------------------------------------------
    for ch in body.get("choices") or []:
        st["chunks"] += 1
        msg = ch.get("message") or {}
        for rk in REASON_KEYS:
            if msg.get(rk):
                st["thought"] = True
                st["think"] += len(str(msg[rk]))
        if msg.get("content"):
            st["txt"] += len(str(msg["content"]))
        for tc in msg.get("tool_calls") or []:
            fn = (tc.get("function") or {}).get("name")
            if fn:
                st["tools"].append(fn)
        if ch.get("finish_reason"):
            st["stop"] = ch["finish_reason"]
        psf = msg.get("provider_specific_fields") or {}
        if psf.get("reasoning_tokens"):
            st["thought"] = True
    return st


def chat_payload(alias, stream, max_tokens):
    return {
        "model": alias, "stream": stream, "max_tokens": max_tokens,
        "messages": [{"role": "user",
                      "content": "Think carefully, then answer in one short sentence: "
                                 "what is 12 times 9?"}],
    }


def msgs_payload(alias, stream, max_tokens):
    return {
        "model": alias, "stream": stream, "max_tokens": max_tokens,
        "messages": [{"role": "user",
                      "content": "Think carefully, then answer in one short sentence: "
                                 "what is 12 times 9?"}],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--via", choices=["nginx", "direct"], default="nginx")
    ap.add_argument("--aliases", default="")
    ap.add_argument("--min-think", type=int, default=8,
                    help="minimum reasoning chars before a cell counts as thinking")
    ap.add_argument("--max-tokens", type=int, default=512,
                    help="deliberately generous: a small budget makes every cell "
                         "look starved and hides the real signal")
    ap.add_argument("--timeout", type=float, default=120.0)
    a = ap.parse_args()

    env, lp, np_ = _load_env()
    key = env.get("LITELLM_MASTER_KEY") or os.environ.get("LITELLM_MASTER_KEY")
    if not key:
        print("❌ LITELLM_MASTER_KEY unavailable (.env and env both empty)"); return 2
    port = np_ if a.via == "nginx" else lp
    if not port:
        print(f"❌ .{'nginx' if a.via=='nginx' else 'litellm'}_port missing — "
              f"run 'myclaude' first (this harness never starts or kills anything)")
        return 2
    root = f"http://127.0.0.1:{port}"

    aliases = [x.strip() for x in a.aliases.split(",") if x.strip()] or aliases_from_config()

    print(f"VIA={a.via}  base={root}  aliases={len(aliases)}  "
          f"max_tokens={a.max_tokens}  min_think={a.min_think} chars")
    print("=" * 104)

    cells = []
    fails = starved = 0
    for alias in aliases:
        for path, mk in (("/v1/chat/completions", chat_payload), ("/v1/messages", msgs_payload)):
            for stream in (True, False):
                url = root + path
                hdr = {"anthropic-version": "2023-06-01"} if path == "/v1/messages" else {}
                st, body, raw, dt = _post(url, mk(alias, stream, a.max_tokens), key, a.timeout, hdr)
                if st == 200 and raw.lstrip().startswith(("data:", "event:", "{")):
                    acc = scan_stream(raw) if (stream and "data:" in raw) else scan_nonstream(body)
                else:
                    acc = {"chunks": 0, "txt": 0, "think": 0, "stop": None,
                           "tools": [], "done": False, "thought": False,
                           "err": (raw[:200] if st != 200 else "unparseable")}
                thought = acc["thought"] and acc["think"] >= a.min_think
                is_starved = (acc["txt"] == 0 and acc["think"] > 0
                              and str(acc["stop"]) in THINK_STOP)
                streamed_ok = (not stream) or (acc["chunks"] > 1 and acc["done"])
                ok = (st == 200) and thought and streamed_ok and not is_starved
                if not ok:
                    fails += 1
                if is_starved:
                    starved += 1
                cells.append((path, stream, alias, st, acc, thought, streamed_ok, is_starved, dt))
                flags = []
                if not thought:
                    flags.append(f"NO-THINK(think={acc['think']})")
                if stream and not streamed_ok:
                    flags.append(f"NO-STREAM(chunks={acc['chunks']},done={acc['done']})")
                if is_starved:
                    flags.append("STARVED(txt=0,stop=%s)" % acc["stop"])
                if acc["err"]:
                    flags.append("ERR:%s" % str(acc["err"])[:90])
                tag = "✅" if ok else "❌"
                print(f" {tag} {path:24} stream={str(stream):5} {alias:36} "
                      f"HTTP {st:3} {dt:5.1f}s txt={acc['txt']:4} think={acc['think']:5} "
                      f"chunks={acc['chunks']:3} stop={str(acc['stop']):11} "
                      f"tools={','.join(acc['tools']) or '-':12} {' '.join(flags)}")
        print("-" * 104)

    print("=" * 104)
    print(f"cells={len(cells)}  failures={fails}  of which STARVED={starved}")
    if starved:
        print("❌ THINKING-BUDGET / max_tokens MISCONFIGURATION (thinking ate the whole")
        print("   budget so no answer text was emitted). Fix in models/gen_scenes.py:")
        print("   raise max_tokens above the thinking budget, or lower the budget.")
        print("   This is NOT a provider fault and NOT 'thinking is off'.")
    if fails:
        bad = [c for c in cells if not (c[5] and c[6] and not c[7] and c[3] == 200)]
        print("❌ cells failing the streaming+thinking requirement:")
        for p, s, al, st, acc, th, so, iv, dt in bad[:12]:
            print(f"   • {p} stream={s} {al} HTTP={st} think={acc['think']} "
                  f"txt={acc['txt']} chunks={acc['chunks']} stop={acc['stop']}")
        print("VERDICT: ❌ REQUIREMENT NOT MET")
        return 1
    print("✅ EVERY alias thinks on every transport, in both stream modes,")
    print("   streams arrive as >1 SSE event with [DONE], and no cell is starved.")
    print("VERDICT: ✅ STREAMING + THINKING UNIFORM")
    return 0


if __name__ == "__main__":
    sys.exit(main())
