# 🤖 MyClaude — Claude Code + NVIDIA NIM Proxy

Runs [Claude Code](https://docs.anthropic.com/en/docs/claude-code) through a local [LiteLLM](https://github.com/BerriAI/litellm) proxy backed by NVIDIA NIM models:

| Claude model | NVIDIA NIM backend |
|---|---|
| `claude-opus-5` | Nemotron 3 Ultra |
| `claude-sonnet-5` | StepFun Step-3.7-Flash |

## Prerequisites

- Linux with systemd
- Python 3.10+
- NVIDIA NIM API key ([build.nvidia.com](https://build.nvidia.com))
- Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- nginx

## Install

```bash
git clone https://github.com/<user>/myclaude.git
cd myclaude
bash install.sh
```

The installer will:
1. Ask for your NVIDIA API key (and validate it)
2. Create a dedicated `myclaude` system user
3. Set up a Python venv with LiteLLM
4. Configure nginx reverse proxy on port 4000
5. Start `myclaude.service` (systemd)
6. Optionally install Claude Code
7. Add convenience aliases to `~/.bashrc`
8. Offer **local network access** — let other devices on your LAN use MyClaude

## Usage

```bash
myclaude          # launches Claude Code
myclaude --help   # pass args through to Claude Code
```

After install, source your bashrc or open a new terminal to get aliases:
```bash
source ~/.bashrc
myclaude-status   # check proxy status
myclaude-logs     # live proxy logs
```

## Architecture

```
Claude Code
    │
    ▼
nginx :4000  (rate limiting, optional LAN exposure)
    │
    ▼
LiteLLM :4001  (model routing, retries)
    │
    ▼
NVIDIA NIM API
```

## Configuration

| File | Purpose |
|---|---|
| `.env` | Your API keys (gitignored) |
| `.env.example` | Template for `.env` |
| `config.yaml` | LiteLLM routing & model config |
| `nginx-myclaude.conf` | Nginx reverse proxy |
| `litellm.service.template` | Systemd unit (paths templated at install) |

## Network Access

See [LAN-ACCESS.md](LAN-ACCESS.md) for connecting phones, tablets, and other PCs.

## Management

```bash
sudo systemctl restart myclaude    # restart proxy
journalctl -u myclaude -f          # live logs
sudo systemctl stop myclaude       # stop proxy
```
