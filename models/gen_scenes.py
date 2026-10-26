#!/usr/bin/env python3
"""Deterministic generator for scenes 1-5. Stdlib only.
  source tests/env.sh && python3 models/gen_scenes.py && ./build_config.sh

Chain: Ultra-550B -> 3.5-Super -> Ultra-550B.
"3.5-Super" is selectable because /v1/models lies and only a live POST decides:
  DEFAULT (proven live):  nvidia_nim/nvidia/nemotron-3.5-super-vl-120b-a12b
      -> gateway echoes private/nemotron-3.5-super-120b-a12b (SAME model)
  CANDIDATE (404-proved): nvidia_nim/nvidia/nemotron-3.5-super-120b-a12b
      -> do NOT set MYCLAUDE_SUPER_MODEL to this unless a fresh diag_model run
         returns OK on all keys.
"""
import os

HERE = os.path.dirname(os.path.abspath(__file__))

ULTRA  = "nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b"
SUPER  = os.getenv("MYCLAUDE_SUPER_MODEL",
                   "nvidia_nim/nvidia/nemotron-3.5-super-vl-120b-a12b")
OMNI   = "nvidia_nim/nvidia/nemotron-3-nano-omni-30b-a3b-reasoning"
KEYS   = [f"NVIDIA_API_KEY_{i}" for i in range(1, 7)]
PER_KEY, TIMEOUT, V_TIMEOUT = 7, 600, 900

# Anything carrying a dead/retired brand must never reach config.yaml.
BANNED = ("nemotron-3-super-120b", "nemotron-3.5-super-120b-a12b",   # bare name = 404
          "nemotron-4-340b", "nemotron-nano-3-30b", "nemotron-ultra-253b",
          "phi-3-vision", "llama-3.2-90b-vision", "llama-3.2-11b-vision",
          "deepseek", "starcoder", "codestral", "granite", "gemma",
          "mistral", "yi-large", "20240620")


def entry(alias, model, key, temp, max_tokens, timeout, think=True, vis=False, extra=""):
    tp = ", chat_template_kwargs: {enable_thinking: true}" if think else ""
    vi = ", supports_vision: true" if vis else ""
    return (f"- model_name: {alias}\n"
            f"  litellm_params: {{model: {model}, api_key: os.environ/{key}, temperature: {temp}, "
            f"top_p: 0.95, max_tokens: {max_tokens}, drop_params: true, num_retries: 3, "
            f"timeout: {timeout}, max_parallel_requests: {PER_KEY}{extra}{tp}}}\n"
            f"  model_info: {{mode: chat{vi}}}\n")


def chat_scene(alias, offset, title):
    out = [f"# {title}\n# Alias: {alias} | 12 entries | 6 keys | Ultra -> 3.5-Super -> Ultra\n"
           f"# super variant: {SUPER}\n"
           f"# {PER_KEY} max_parallel_requests/deployment => {PER_KEY*2}/key\n"]
    for i in range(6):
        k = KEYS[(offset + i) % 6]
        out.append(entry(alias, ULTRA, k, 1.0, 16384, TIMEOUT))
        out.append(entry(alias, SUPER, k, 1.0, 16384, TIMEOUT))
    return "".join(out)


def vision_scene(alias, title):
    out = [f"# {title}\n# Alias: {alias} | 12 entries | 6 keys x 2 | nano-omni ONLY | unified name\n"]
    for k in KEYS:
        for _ in range(2):
            out.append(entry(alias, OMNI, k, 0.6, 65536, V_TIMEOUT,
                             think=True,  vis=True, extra=", reasoning_budget: 16384"))
    return "".join(out)


SCENES = {
    "scene_1_default.yaml":   chat_scene("claude-opus-5",     0, "Scene 1: Default"),
    "scene_2_opus_1m.yaml":   chat_scene("claude-opus-5-1m",  2, "Scene 2: Opus 1M"),
    "scene_3_sonnet.yaml":    chat_scene("claude-sonnet-5",   4, "Scene 3: Sonnet"),
    "scene_4_sonnet_1m.yaml": chat_scene("claude-sonnet-5-1m",1, "Scene 4: Sonnet 1M"),
    "scene_5_vision.yaml":    vision_scene("claude-3-5-sonnet-20241022-vision", "Scene 5: Vision"),
}

if __name__ == "__main__":
    print(f"super variant in use: {SUPER}")
    for fname, body in SCENES.items():
        hits = [b for b in BANNED if b in body]
        if hits:
            raise SystemExit(f"❌ {fname} would emit BANNED model(s): {hits}")
        with open(os.path.join(HERE, fname), "w") as fh:
            fh.write(body)
        print(f"  ✓ {fname}: {body.count('- model_name:')} entries")
    print("✅ scenes 1-5 regenerated")
