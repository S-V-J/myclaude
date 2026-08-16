# 🤖 MyClaude — Claude Code via NVIDIA NIM Proxy

[![Sponsor](https://img.shields.io/badge/Sponsor-❤️-red)](https://github.com/sponsors/S-V-J)
[![GitHub stars](https://img.shields.io/badge/GitHub%20stars-⭐-yellow)](https://github.com/S-V-J/myclaude/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

MyClaude lets you run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) using NVIDIA NIM models instead of Anthropic's API. It sets up a local LiteLLM proxy that translates Anthropic-format requests into OpenAI-compatible calls to NVIDIA's infrastructure — no code changes to Claude Code needed.

## ✅ Current Status: 100% Functional

All 4 models tested and working:

| Menu Option | Model Name | NVIDIA NIM Backend | Status |
|-------------|------------|-------------------|--------|
| 1. Default (recommended) | `claude-opus-5` | nvidia/nemotron-3-ultra-550b-a55b | ✅ Works |
| 2. Opus (1M context) | `claude-opus-5` | nvidia/nemotron-3-ultra-550b-a55b | ✅ Works |
| 3. Sonnet | `claude-sonnet-5` | stepfun-ai/step-3.7-flash | ✅ Works |
| 4. Sonnet 5 (1M context) | `claude-sonnet-5-1m` | minimaxai/minimax-m3 | ✅ Works |
| 5. Haiku | `claude-haiku-4-5` | poolside/laguna-xs-2.1 | ✅ Works |

## ⚠️ Important: Bring Your Own NVIDIA API Keys

**You must have your own NVIDIA NIM API keys to use this system.** The installer does not provide keys.

Get free API keys at: https://build.nvidia.com

Each model backend may require a different API key:
- **Nemotron 3 Ultra** (Opus) → NVIDIA_API_KEY
- **StepFun Step-3.7-Flash** (Sonnet) → STEPFUN_API_KEY (optional, falls back to NVIDIA key)
- **Minimax M3** (Sonnet 1M) → MINIMAX_API_KEY (optional, falls back to NVIDIA key)
- **Poolside Laguna XS** (Haiku) → POOLSIDE_API_KEY (optional, falls back to NVIDIA key)

## How It Works

<div class="mermaid">

flowchart LR
    subgraph Client["Client Machine"]
        CC[("Claude Code\n(Anthropic SDK)")]
    end

    subgraph Proxy["Local Proxy Stack (localhost)"]
        direction TB
        NX["nginx :4000\nRate Limiter\n16 req/s · burst 32"]
        LL["LiteLLM :4001\nProxy & Router\nAnthropic to OpenAI"]
    end

    subgraph NVIDIA["NVIDIA NIM Cloud"]
        direction TB
        NM["Nemotron 3 Ultra\nnvidia/nemotron-3-ultra-550b-a55b"]
        SM["StepFun Step-3.7-Flash\nstepfun-ai/step-3.7-flash"]
        MM["Minimax M3\nminimaxai/minimax-m3"]
        PM["Poolside Laguna XS\npoolside/laguna-xs-2.1"]
    end

    CC -->|Anthropic Messages API\nhttp://localhost:4000| NX
    NX -->|HTTP/1.1 + WebSocket\nRate limited| LL
    LL -->|OpenAI Chat Completions\n+ NVIDIA headers| NM
    LL -->|OpenAI Chat Completions\n+ NVIDIA headers| SM
    LL -->|OpenAI Chat Completions\n+ NVIDIA headers| MM
    LL -->|OpenAI Chat Completions\n+ NVIDIA headers| PM

    classDef client fill:#1a1a2e,stroke:#00d4ff,stroke-width:2px,color:#fff
    classDef proxy fill:#16213e,stroke:#e94560,stroke-width:2px,color:#fff
    classDef nvidia fill:#0f0f23,stroke:#76b900,stroke-width:2px,color:#fff

    class CC client
    class NX,LL proxy
    class NM,SM,MM,PM nvidia

</div>

### Request Flow

| Step | Component | Protocol | Details |
|------|-----------|----------|---------|
| 1 | **Claude Code** → nginx | HTTP/1.1 + SSE | Anthropic Messages format, `http://localhost:4000` |
| 2 | **nginx** → LiteLLM | HTTP/1.1 + WebSocket | Rate limited (16 req/s, burst 32), queues overflow |
| 3 | **LiteLLM** → NVIDIA NIM | OpenAI Chat Completions | Translates format, selects model via router, adds auth |
| 4 | **NVIDIA NIM** → Client | SSE Streaming | Model inference, streams tokens back through chain |

### Model Routing Map

<div class="mermaid">

flowchart TB
    subgraph Claude["Claude Code Models"]
        CO5["claude-opus-5\n(Default / Opus 1M)"]
        CS5["claude-sonnet-5\n(Sonnet)"]
        CS51M["claude-sonnet-5-1m\n(Sonnet 1M)"]
        CH45["claude-haiku-4-5\n(Haiku)"]
    end

    subgraph NVIDIA["NVIDIA NIM Backends"]
        NEMO["Nemotron 3 Ultra\nReasoning · 1M context"]
        STEP["StepFun Step-3.7-Flash\nReasoning · Fast"]
        MINI["Minimax M3\n1M context"]
        POOL["Poolside Laguna XS\nFast · Coding"]
    end

    CO5 -->|NVIDIA_API_KEY| NEMO
    CS5 -->|STEPFUN_API_KEY| STEP
    CS51M -->|MINIMAX_API_KEY| MINI
    CH45 -->|POOLSIDE_API_KEY| POOL

    classDef claude fill:#1a1a2e,stroke:#00d4ff,stroke-width:2px,color:#fff
    classDef nvidia fill:#0f0f23,stroke:#76b900,stroke-width:2px,color:#fff

    class CO5,CS5,CS51M,CH45 claude
    class NEMO,STEP,MINI,POOL nvidia

</div>

## Why This Approach

- **No Anthropic API subscription needed** — uses NVIDIA NIM credits
- **Drop-in replacement** — Claude Code works unmodified, just pointed at a different URL
- **Rate limit protection** — nginx queues burst traffic; LiteLLM retries with backoff
- **Model routing** — different Claude models map to different NVIDIA backends automatically
- **Local-first** — everything runs on your machine, keys never leave your control

## Prerequisites

- **NVIDIA NIM API key(s)** — free tier available at [build.nvidia.com](https://build.nvidia.com)
- **Linux** with systemd (Ubuntu, Debian, WSL2, etc.)
- **Python 3.10+**
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **nginx** — `sudo apt install nginx`
- **sudo access** — for system user creation and service setup

## Installation

### Option 1: Interactive TUI Installer (Recommended)

```bash
git clone https://github.com/S-V-J/myclaude.git && cd myclaude && bash install.sh
```

The installer launches a **Terminal User Interface (TUI)** that guides you through complete configuration:

#### TUI Configuration Flow

```
┌──────────────────────────────────────────────────────────────┐
│                      MyClaude Installer                       │
│               NVIDIA NIM Proxy for Claude Code               │
└──────────────────────────────────────────────────────────────┘

Step 1: API Keys (up to 4)
──────────────────────────────────────────────────────────────
┌─ Key 1 ──────────────────────────────────────────────────────┐
│ Label:      [Primary NVIDIA           ] ▼  (required)       │
│ API Key:    [nvapi-********************]                      │
│ Base URL:   [https://integrate.api.nvidia.com/v1 ] ▼        │
│ ─────────────────────────────────────────────────────────── │
│ Models available for this key (fetch from /v1/models):      │
│   ☐ nemotron-3-ultra-550b-a55b   ☐ nemotron-4-340b        │
│   ☐ llama-3.1-nemotron-70b       ☐ ...                     │
└──────────────────────────────────────────────────────────────┘
┌─ Key 2 ──────────────────────────────────────────────────────┐
│ Label:      [StepFun                  ] ▼  (optional)       │
│ API Key:    [nvapi-********************]                      │
│ Base URL:   [https://integrate.api.nvidia.com/v1 ] ▼        │
│ Models:     ☐ step-3.7-flash      ☐ step-3.7-mini  ☐ ...   │
└──────────────────────────────────────────────────────────────┘
┌─ Key 3 ──────────────────────────────────────────────────────┐
│ Label:      [Minimax                ] ▼  (optional)          │
│ API Key:    [nvapi-********************]                      │
│ Base URL:   [https://integrate.api.nvidia.com/v1 ] ▼        │
│ Models:     ☐ minimax-m3          ☐ minimax-m1     ☐ ...     │
└──────────────────────────────────────────────────────────────┘
┌─ Key 4 ──────────────────────────────────────────────────────┐
│ Label:      [Poolside               ] ▼  (optional)          │
│ API Key:    [nvapi-********************]                      │
│ Base URL:   [https://integrate.api.nvidia.com/v1 ] ▼        │
│ Models:     ☐ laguna-xs-2.1       ☐ laguna-xs-1.5  ☐ ...     │
└──────────────────────────────────────────────────────────────┘

        [Fetch Models]   [Validate Keys]   [Next: Model Mapping →]
```

```
Step 2: Model Mapping — Map Claude Models to NVIDIA Backends
──────────────────────────────────────────────────────────────
┌─ claude-opus-5 (Default / Opus 1M) ─────────────────────────┐
│ Backend: [Key 1: nemotron-3-ultra-550b-a55b           ] ▼   │
│ Params:  temp=1.0  top_p=0.95  max_tokens=16384  thinking=on│
│ Raw Payload Editor: [Edit ▼]                                 │
└──────────────────────────────────────────────────────────────┘
┌─ claude-sonnet-5 (Sonnet) ──────────────────────────────────┐
│ Backend: [Key 2: step-3.7-flash                         ] ▼   │
│ Params:  temp=1.0  top_p=0.95  max_tokens=16384              │
│ Raw Payload Editor: [Edit ▼]                                 │
└──────────────────────────────────────────────────────────────┘
┌─ claude-sonnet-5-1m (Sonnet 1M) ────────────────────────────┐
│ Backend: [Key 3: minimax-m3                               ] ▼   │
│ Params:  temp=1.0  top_p=0.95  max_tokens=8192               │
│ Raw Payload Editor: [Edit ▼]                                 │
└──────────────────────────────────────────────────────────────┘
┌─ claude-haiku-4-5 (Haiku) ──────────────────────────────────┐
│ Backend: [Key 4: laguna-xs-2.1                            ] ▼   │
│ Params:  temp=1.0  top_p=0.95  max_tokens=8192               │
│ Raw Payload Editor: [Edit ▼]                                 │
└──────────────────────────────────────────────────────────────┘

Flexible Mapping:
  ├── 1 Key → 1 Model  (dedicated key per model)
  ├── 1 Key → 4 Models (single key, multiple backends)
  ├── 2 Keys → 4 Models (mixed)
  └── Any combination you choose

       [Validate All]   [Test Each Model]   [Next: Advanced →]
```

```
Step 3: Advanced Options
──────────────────────────────────────────────────────────────
  ☐ Enable LAN Access (0.0.0.0:4000 + firewall rules)
  ☐ Custom nginx rate limits (default: 16 req/s, burst 32)
  ☐ Custom timeouts (default: 3600s)
  ☐ Enable request/response logging
  ☐ Auto-restart on failure (systemd)

       [Install]   [Back]   [Save Config Only]
```

```
Step 4: Raw Payload Validation (Optional but Recommended)
──────────────────────────────────────────────────────────────
For each model, you can edit the exact JSON payload sent to NVIDIA:

┌─ claude-opus-5 Raw Payload ─────────────────────────────────┐
│ {                                                              │
│   "model": "nvidia/nemotron-3-ultra-550b-a55b",              │
│   "messages": [{"role": "user", "content": "{{PROMPT}}"}],   │
│   "temperature": 1.0,                                         │
│   "top_p": 0.95,                                              │
│   "max_tokens": 16384,                                        │
│   "seed": 42,                                                 │
│   "stream": false,                                            │
│   "extra_body": {                                             │
│     "chat_template_kwargs": {"enable_thinking": true},       │
│     "reasoning_budget": 16384                                 │
│   }                                                           │
│ }                                                             │
│                                                               │
│ [Test This Payload]  [Validate JSON]  [Reset to Default]    │
└──────────────────────────────────────────────────────────────┘
```

#### TUI Features

| Feature | Description |
|---------|-------------|
| **Up to 4 API Keys** | Configure multiple NVIDIA keys for different model providers |
| **Service Provider URL** | Select or enter custom base URLs (default: NVIDIA integrate API) |
| **Model Discovery** | Click "Fetch Models" to auto-populate available models per key |
| **Flexible Mapping** | Map any key→model combination (1:1, 1:many, many:1) |
| **Raw Payload Editor** | Full JSON editor per model with live validation |
| **Live Testing** | Test each model mapping before installation |
| **Config Persistence** | Saves to `.env` and `config.yaml` automatically |

### Option 2: Automated Install (Makefile)

```bash
git clone https://github.com/S-V-J/myclaude.git && cd myclaude && make install
```

This runs everything non-interactively (requires `NVIDIA_API_KEY` env var).

### Option 3: Windows + WSL

Follow the WSL guide below, then run Option 1 or 2 inside WSL.

### WSL — Step-by-Step Setup

**1. Open PowerShell as Administrator**
Press `Win + X` → Select "Windows Terminal (Admin)" or "PowerShell (Admin)"

**2. Install Ubuntu 26.04 via WSL2**
```bash
wsl --install -d Ubuntu-26.04 --name myclaude --web-download
```

**3. Create Your Linux User**
```
Enter new UNIX username: myclaude
New password: ********
Retype new password: ********
```

**4. Run the installer**
```bash
git clone https://github.com/S-V-J/myclaude.git && cd myclaude && bash install.sh
```

## Usage

```bash
myclaude              # launch Claude Code with NVIDIA models
myclaude --help       # pass arguments through to Claude Code
myclaude "prompt"     # one-shot prompt
```

### Model Selection in Claude Code

When you run `myclaude`, Claude Code will show the model selector:

```
Select model
Switch between Claude models. Your pick becomes the default for new sessions.

  1. Default (recommended)  : proxy ai model nvidia/nemotron-3-ultra-550b-a55b
❯ 2. Opus (1M context) ✔    : proxy ai model nvidia/nemotron-3-ultra-550b-a55b
  3. Sonnet                 : proxy ai model stepfun-ai/step-3.7-flash
  4. Sonnet 5 (1M context)  : proxy ai model minimaxai/minimax-m3
  5. Haiku                  : proxy ai model poolside/laguna-xs-2.1
```

Your selection persists across sessions via Claude Code's config.

### Service Management

```bash
sudo systemctl status myclaude   # check if proxy is running
sudo systemctl restart myclaude  # restart after config changes
sudo systemctl stop myclaude     # stop the proxy
journalctl -u myclaude -f        # live log tail
```

### Convenience Aliases

After `source ~/.bashrc` or opening a new terminal:

```bash
myclaude-status  # sudo systemctl status myclaude
myclaude-logs    # journalctl -u myclaude -f
myclaude-start   # sudo systemctl start myclaude
myclaude-stop    # sudo systemctl stop myclaude
```

## Configuration Reference

| File | Purpose |
|------|---------|
| `.env` | Your API keys (gitignored, created by installer) |
| `.env.example` | Template showing required variables |
| `config.yaml` | LiteLLM model routing, retry settings, rate limits |
| `nginx-myclaude.conf` | nginx reverse proxy, rate limiting, timeouts |
| `litellm.service.template` | systemd unit template (paths filled at install) |
| `myclaude.sh` | `/usr/local/bin/myclaude` wrapper script |
| `install.sh` | TUI installer |

### .env Variables

```env
# Required — Primary NVIDIA NIM key (get at build.nvidia.com)
NVIDIA_API_KEY="nvapi-..."

# Optional — Separate keys for specific model providers (fallback to NVIDIA_API_KEY)
STEPFUN_API_KEY="nvapi-..."
MINIMAX_API_KEY="nvapi-..."
POOLSIDE_API_KEY="nvapi-..."

# Auto-generated — local proxy auth key (used by Claude Code)
LITELLM_MASTER_KEY="sk-local-..."

# Required — forces Anthropic message format compatibility
LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="true"
```

### LiteLLM Config (`config.yaml`)

Key settings (managed by TUI installer):
- **Routing strategy**: `least-busy` — picks the model with fewest active requests
- **Fallbacks**: `claude-opus-5` → `claude-sonnet-5` on failure
- **Retries**: 5 attempts, 5s cooldown between retries
- **Parallel limits**: 15 max concurrent (stays safely under NVIDIA's 20 RPM tier)
- **Timeouts**: 3600s request timeout for long-running tasks

## Local Network Access

Other devices on your LAN (phones, tablets, other PCs) can also use MyClaude. The TUI installer offers this option and handles nginx binding + firewall rules.

Full guide: [LAN-ACCESS.md](LAN-ACCESS.md)

## Architecture Deep-Dive

### Request Flow

1. **Claude Code** formats a request as an Anthropic Messages API call
2. **nginx** receives it on `:4000`, applies rate limiting (16 req/s sustained, 32 burst), and forwards to LiteLLM
3. **LiteLLM** receives the Anthropic-format request, translates headers and body to OpenAI format, selects the target model via the complexity router, and forwards to NVIDIA NIM
4. **NVIDIA NIM** runs inference and streams SSE chunks back through the chain to Claude Code

### Why nginx in front of LiteLLM?

- **Burst absorption**: Claude Code can fire rapid parallel tool calls; nginx queues them smoothly
- **503 on overload**: Returns clean errors instead of crashing LiteLLM under load
- **WebSocket upgrade**: Proper streaming support for long completions
- **Future-proof**: Easy to add TLS, auth, or multi-tenant routing at the nginx layer

### Why a dedicated system user?

- Security isolation — the proxy runs with minimal privileges
- Clean ownership — venv, logs, and config all owned by one user
- No shell access — `nologin` shell prevents interactive logins

## Troubleshooting

| Issue | Fix |
|-------|-----|
| `myclaude: command not found` | Re-login or run `source ~/.bashrc` |
| `Failed to start LiteLLM` | Check `journalctl -u myclaude -n 20` for errors |
| `API key rejected` | Re-run installer, or edit `.env` and `sudo systemctl restart myclaude` |
| `Connection refused` | `sudo systemctl status myclaude` — service may have failed |
| `Port 4000 already in use` | Another service is using the port — check `sudo ss -tlnp \| grep 4000` |
| Slow responses | Check NVIDIA NIM status; try reducing `max_tokens` in config.yaml |
| Model returns 429 | API key rate limited — wait or use different key |
| TUI not displaying | Ensure terminal supports ANSI colors (most do) |

## Development / Contributing

```bash
# Run tests
make test

# Lint shell scripts
shellcheck install.sh myclaude.sh

# Validate config.yaml
yamllint config.yaml
```

## Sponsor

If this project saves you API costs or makes your workflow better, consider sponsoring:

[![Sponsor](https://img.shields.io/badge/Sponsor-❤️-red)](https://github.com/sponsors/S-V-J)

Your support helps keep the project maintained and adds new model integrations.

## License

MIT — see [LICENSE](LICENSE) for details.