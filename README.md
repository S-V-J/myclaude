# 🤖 MyClaude — Claude Code via NVIDIA NIM Proxy

[![Sponsor](https://img.shields.io/badge/Sponsor-❤️-red)](https://github.com/sponsors/S-V-J)
[![GitHub stars](https://img.shields.io/badge/GitHub%20stars-⭐-yellow)](https://github.com/S-V-J/myclaude/stargazers)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

MyClaude lets you run [Claude Code](https://docs.anthropic.com/en/docs/claude-code) using NVIDIA NIM models instead of Anthropic's API. It sets up a local LiteLLM proxy that translates Anthropic-format requests into OpenAI-compatible calls to NVIDIA's infrastructure — no code changes to Claude Code needed.

## How It Works

```
              :4000              :4001
                  ┌──────────┐       ┌──────────┐
                  │ Claude   │──────▶│  nginx   │──────▶│ LiteLLM │
                  │  Code    │◀──────│ (rate    │◀──────│ (proxy) │
                  │(Anthropic)│       │  limit)  │       └────┬─────┘
                  └──────────┘       └──────────┘            │
                                                             ▼
                                                ┌──────────────────────┐
                                                │   NVIDIA NIM API     │
                                                │  ┌────────────────┐  │
                                                │  │ claude-opus-5  │  │
                                                │  │→ Nemotron Ultra│  │
                                                │  ├────────────────┤  │
                                                │  │claude-sonnet-5 │  │
                                                │  │→ Step-3.7 Flash│  │
                                                │  └────────────────┘  │
                                                └──────────────────────┘
```

1. **Claude Code** sends Anthropic-format requests to `http://localhost:4000`
2. **nginx** reverse-proxies with rate limiting (burst-aware queuing) to LiteLLM
3. **LiteLLM** translates Anthropic messages → OpenAI format and routes to the right NVIDIA model
4. **NVIDIA NIM** executes the model inference and streams results back

## Why This Approach

- **No Anthropic API subscription needed** — uses NVIDIA NIM credits
- **Drop-in replacement** — Claude Code works unmodified, just pointed at a different URL
- **Rate limit protection** — nginx queues burst traffic; LiteLLM retries with backoff
- **Model routing** — different Claude models map to different NVIDIA backends automatically
- **Local-first** — everything runs on your machine, keys never leave your control

## Model Routing

| Claude Model | NVIDIA NIM Backend | Use Case |
|---|---|---|
| `claude-opus-5` | Nemotron 3 Ultra | Heavy reasoning, complex tasks |
| `claude-sonnet-5` | StepFun Step-3.7-Flash | Fast responses, standard coding |

LiteLLM's complexity router evaluates each prompt and routes `claude-opus-5` requests to Nemotron 3 Ultra by default, with automatic fallback to `claude-sonnet-5` if the primary model is unavailable or rate-limited.

## Prerequisites

- **NVIDIA NIM API key** — free tier available at [build.nvidia.com](https://build.nvidia.com) (easy to create, watch a YouTube tutorial if needed)
- **Linux** with systemd (Ubuntu, Debian, WSL2, etc.)
- **Python 3.10+**
- **Claude Code CLI** — `npm install -g @anthropic-ai/claude-code`
- **nginx** — `sudo apt install nginx`
- **sudo access** — for system user creation and service setup

## Installation

### Option 1: Makefile (Fully Automated — Recommended)

```bash
git clone https://github.com/S-V-J/myclaude.git && cd myclaude && make install
```

This runs **everything** automatically:
- `apt update && apt upgrade -y`
- Installs `nginx`, `python3`, `python3-venv`, `python3-pip`, `curl`, `git`
- Creates system user `myclaude`
- Sets up Python venv + LiteLLM with FastAPI fix
- Configures nginx reverse proxy with rate limiting
- Installs systemd service with auto-restart
- Installs Claude Code CLI via npm
- Adds `myclaude` command wrapper and bash aliases
- Verifies the full proxy chain works

### Option 2: Original Installer (Interactive)

```bash
git clone https://github.com/S-V-J/myclaude.git && cd myclaude && bash install.sh
```

This prompts for your NVIDIA API key and optional LAN access.

### Option 3: Windows + WSL

If you have **Windows only**, follow the WSL guide below.

### WSL — Step-by-Step Setup

**1. Open PowerShell as Administrator**

Press `Win + X` → Select "Windows Terminal (Admin)" or "PowerShell (Admin)" and confirm the UAC prompt.

**2. Install Ubuntu 26.04 via WSL2**

Check available versions:
```bash
wsl --list --online
```

Install:
```bash
wsl --install -d Ubuntu-26.04 --name myclaude --web-download
```

*(`myclaude` is just an example name — feel free to change it.)*

**Command Breakdown:**

| Part | Purpose |
|---|---|
| `wsl --install` | Installs the WSL feature |
| `-d Ubuntu-26.04` | Specific Ubuntu version |
| `--name myclaude` | Friendly WSL instance name |
| `--web-download` | Download from Microsoft Store catalog |

**3. Create Your Linux User**

When the installation completes, a terminal window will open asking for:
```
Enter new UNIX username: myclaude     ← create your own
New password: ********               ← choose a password
Retype new password: ********
```

**4. Run the installer**

Once inside your WSL Ubuntu terminal:
```bash
git clone https://github.com/S-V-J/myclaude.git && cd myclaude && bash install.sh
```

The installer handles everything — Python venv, LiteLLM, nginx, systemd service, the works.

### What the installer does

1. **Validates your NVIDIA API key** — makes a live test call before proceeding
2. **Creates system user `myclaude`** — isolated, no login shell, owns all service files
3. **Sets up Python venv + LiteLLM** — installs with the FastAPI compatibility fix
4. **Configures nginx** — reverse proxy on port 4000 with request queuing
5. **Starts `myclaude.service`** — systemd-managed, auto-restarts on failure
6. **Handles Claude Code** — detects existing install (skip), or offers to install/repair
7. **Updates `~/.bashrc`** — adds `myclaude-status`, `myclaude-logs` aliases
8. **Installs `myclaude` command** — wrapper at `/usr/local/bin/myclaude`
9. **Optional: LAN access** — expose on your local network for phones, tablets, other PCs

## Usage

```bash
myclaude              # launch Claude Code with NVIDIA models
myclaude --help       # pass arguments through to Claude Code
myclaude "prompt"     # one-shot prompt
```

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
|---|---|
| `.env` | Your API keys (gitignored, created by installer) |
| `.env.example` | Template showing required variables |
| `config.yaml` | LiteLLM model routing, retry settings, rate limits |
| `nginx-myclaude.conf` | nginx reverse proxy, rate limiting, timeouts |
| `litellm.service.template` | systemd unit template (paths filled at install) |
| `myclaude.sh` | `/usr/local/bin/myclaude` wrapper script |
| `install.sh` | One-command installer |

### .env Variables

```env
# Required — NVIDIA NIM key (get at build.nvidia.com)
NVIDIA_API_KEY="nvapi-..."

# Optional — separate key for StepFun models (falls back to NVIDIA key)
STEPFUN_API_KEY="nvapi-..."

# Auto-generated — local proxy auth key (used by Claude Code)
LITELLM_MASTER_KEY="sk-local-..."

# Required — forces Anthropic message format compatibility
LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="true"
```

### LiteLLM Config (`config.yaml`)

Key settings:
- **Routing strategy**: `least-busy` — picks the model with fewest active requests
- **Fallbacks**: `claude-opus-5` → `claude-sonnet-5` on failure
- **Retries**: 5 attempts, 5s cooldown between retries
- **Parallel limits**: 15 max concurrent (stays safely under NVIDIA's 20 RPM tier)
- **Timeouts**: 3600s request timeout for long-running tasks

## Local Network Access

Other devices on your LAN (phones, tablets, other PCs) can also use MyClaude. The installer offers this option and handles nginx binding + firewall rules.

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
|---|---|
| `myclaude: command not found` | Re-login or run `source ~/.bashrc` |
| `Failed to start LiteLLM` | Check `journalctl -u myclaude -n 20` for errors |
| `API key rejected` | Re-run installer, or edit `.env` and `sudo systemctl restart myclaude` |
| `Connection refused` | `sudo systemctl status myclaude` — service may have failed |
| `Port 4000 already in use` | Another service is using the port — check `sudo ss -tlnp \| grep 4000` |
| Slow responses | Check NVIDIA NIM status; try reducing `max_tokens` in config.yaml |

## Sponsor

If this project saves you API costs or makes your workflow better, consider sponsoring:

[![Sponsor](https://img.shields.io/badge/Sponsor-❤️-red)](https://github.com/sponsors/S-V-J)

Your support helps keep the project maintained and adds new model integrations.

## License

MIT — see [LICENSE](LICENSE) for details.
