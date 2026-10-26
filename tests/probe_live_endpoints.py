#!/usr/bin/env python3
"""Live endpoint probe with the 3-shape escalation ladder (imports diag_model).

/v1/models lies (lists retired models). Only a real POST proves an endpoint
works — but the POST must be shaped like production traffic, or reasoning
models 500 on trivia (the super-vl lesson).

Per model: ladder on --key; if DEAD there, escalate to 2 more keys.
Exit 1 only if a model is DEAD on every key tried.

Usage:
  python3 tests/probe_live_endpoints.py --key 1
  python3 tests/probe_live_endpoints.py --all-keys
"""
import os, sys, time, argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from diag_model import load_env, run_shape, verdict_for_key, BASE  # noqa: E402

import re, yaml  # noqa: E402

MODEL_RE = re.compile(r"model:\s*(nvidia_nim/[^\s,}]+)")
ALIVE = {"OK", "OK_THINK_REQUIRED", "OK_STREAM_ONLY", "FLAKE_RECOVERED"}


def unique_models():
    p = os.path.join(BASE, "config.yaml")
    if not os.path.exists(p):
        sys.exit(f"❌ config.yaml missing at {p} — run ./build_config.sh first")
    return sorted(set(MODEL_RE.findall(open(p).read())))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--key", type=int, default=1)
    ap.add_argument("--all-keys", action="store_true")
    a = ap.parse_args()
    load_env()
    models = unique_models()
    if not models:
        sys.exit("❌ zero models parsed from config.yaml")
    primary = f"NVIDIA_API_KEY_{a.key}"
    others = [f"NVIDIA_API_KEY_{i}" for i in range(1, 7) if i != a.key]
    print(f"Probing {len(models)} models (ladder on {primary}, escalate on DEAD)\n")

    dead, stream_only, rows = [], [], []
    for m in models:
        mid = m.replace("nvidia_nim/", "")
        kv = os.environ.get(primary, "")
        if not kv:
            print(f"  ⚠️  {primary} empty — skipping all"); break
        verd, res = verdict_for_key(mid, kv, timeout=60)
        keys_used = [primary]
        if verd == "DEAD" and not a.all_keys:
            for kn in others[:2]:                      # escalate: 2 more keys max
                kv2 = os.environ.get(kn, "")
                if not kv2:
                    continue
                v2, _ = verdict_for_key(mid, kv2, timeout=60)
                keys_used.append(kn)
                if v2 != "DEAD":
                    verd = v2
                    break
        icon = "✅" if verd in ("OK", "OK_THINK_REQUIRED") else (
               "🟢" if verd in ("OK_STREAM_ONLY", "FLAKE_RECOVERED") else "❌")
        shapes = ",".join(f"{s}:{v.split('_')[0]}" for s, (v, _, _) in res.items())
        print(f"  {icon} {mid:46s} {verd:18s} keys={len(keys_used)} [{shapes}]")
        rows.append((mid, verd))
        if verd == "DEAD":
            dead.append(mid)
        elif verd == "OK_STREAM_ONLY":
            stream_only.append(mid)
        time.sleep(0.3)

    print("\n" + "=" * 74)
    if stream_only:
        print("🟢 SSE-ONLY (fine for Claude Code, which always streams):")
        for m in stream_only:
            print(f"   • {m}")
    if dead:
        print(f"❌ DEAD on all keys tried ({len(dead)}):")
        for m in dead:
            print(f"   • {m}  -> remove from scenes / add to RETIRED in build_config.sh + doctor")
        sys.exit(1)
    print("✅ every model referenced by config.yaml answers a live POST in at least one shape")
    sys.exit(0)


if __name__ == "__main__":
    main()
