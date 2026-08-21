---
name: run-myclaude
description: Run, test, and drive MyClaude — the Claude Code proxy via NVIDIA NIM (Nemotron 3 Ultra with 4 API keys for load isolation). Handles on-demand startup, health checks, model testing, and full proxy chain verification.
---

# MyClaude Run Skill

MyClaude is a local proxy stack that lets **Claude Code** use **NVIDIA NIM** models (Nemotron 3 Ultra) instead of Anthropic's API. It runs:

- **nginx** on port 4000 (HTTP) / 4443 (HTTPS) — rate limiting, TLS termination
- **LiteLLM** on port 4001 — format translation, model routing, NVIDIA NIM calls
- **systemd service** `myclaude` — manages both, with on-demand idle shutdown (5 min default)

All 4 Claude Code models route to the same Nemotron 3 Ultra backend with independent API keys for load isolation (80 RPM combined).

---

## Prerequisites (run once)

```bash
# Ubuntu/Debian/WSL2
sudo apt update && sudo apt install -y nginx python3 python3-venv python3-pip curl git whiptail

# The installer also needs Claude Code CLI (auto-installed via npm):
# npm install -g @anthropic-ai/claude-code
```

---

## Build & Install

The one-command installer handles everything (TUI or `--auto` mode):

```bash
# Interactive TUI
bash install.sh

# Non-interactive (requires NVIDIA_API_KEY_PROJECT_1)
NVIDIA_API_KEY_PROJECT_1="nvapi-..." bash install.sh --auto

# With TLS + LAN (production)
ENABLE_TLS=true TLS_DOMAIN=myclaude.local NVIDIA_API_KEY_PROJECT_1="..." bash install.sh --auto
```

The installer:
1. Creates system user `myclaude`
2. Sets up Python venv + LiteLLM proxy
3. Configures nginx + systemd
4. Installs `/usr/local/bin/myclaude` wrapper (on-demand startup)
5. Writes `~/.claude/settings.json` (MCP servers, Opus 1M, permissive bash)
6. Adds aliases: `myclaude-status`, `myclaude-logs`, `myclaude-start`, `myclaude-stop`

---

## Run (Agent Path) — Use the Driver

**The driver script is the primary way to interact programmatically.** It wraps the on-demand startup, health checks, and model testing.

```bash
# From the repo root (/home/ML/myclaude)
./.claude/skills/run-myclaude/driver.sh <command>
```

### Driver Commands

| Command | Description |
|---------|-------------|
| `start` | Start backend via `myclaude` wrapper (on-demand), wait for health |
| `stop` | Stop backend gracefully (`sudo systemctl stop myclaude`) |
| `status` | Check service + port health (nginx :4000, LiteLLM :4001) |
| `health` | Quick health check (curl both `/health` endpoints) |
| `test` | Run full model test suite (all 4 models) |
| `curl <model> "<prompt>"` | Send a chat completion request to a specific model |
| `logs` | Tail `journalctl -u myclaude -f` |
| `config` | Show current config (models, keys, timeouts) |
| `tls-enable <domain>` | Enable HTTPS via `setup-tls.sh` |
| `tls-disable` | Disable HTTPS, restore HTTP-only |

### Examples

```bash
# Start and verify
./.claude/skills/run-myclaude/driver.sh start
./.claude/skills/run-myclaude/driver.sh health

# Test all models
./.claude/skills/run-myclaude/driver.sh test

# Single model call (useful for CI/verification)
./.claude/skills/run-myclaude/driver.sh curl claude-opus-5 "Say hello"

# With custom prompt
./.claude/skills/run-myclaude/driver.sh curl claude-sonnet-5 "Write a haiku about nginx"

# Check status
./.claude/skills/run-myclaude/driver.sh status

# View live logs
./.claude/skills/run-myclaude/driver.sh logs
```

---

## Run (Human Path)

```bash
# Launch Claude Code interactively (auto-starts backend if needed)
myclaude

# One-shot prompt
myclaude "Explain quantum computing"

# Pass args through to Claude Code
myclaude --help
myclaude --version

# Service management
myclaude-status    # sudo systemctl status myclaude
myclaude-logs      # journalctl -u myclaude -f
myclaude-start     # sudo systemctl start myclaude
myclaude-stop      # sudo systemctl stop myclaude
```

**Note:** The human path spawns an interactive TUI — not suitable for headless/agent use. Use the driver for automation.

---

## Direct Invocation (Internal Code)

For PRs that only touch internal logic (routing, payload building, health checks), you can call LiteLLM directly without the full stack:

```bash
cd /home/ML/myclaude
source .env
source venv/bin/activate

# Run LiteLLM directly (port 4001)
python -m litellm --config config.yaml --port 4001 --host 127.0.0.1

# Or import in Python:
python -c "
from litellm.proxy.proxy_server import initialize
import asyncio
asyncio.run(initialize('config.yaml'))
"
```

Environment variables for direct testing:
```bash
export LITELLM_MASTER_KEY="sk-local-..."
export NVIDIA_API_KEY_PROJECT_1="nvapi-..."
# ... PROJECT_2, PROJECT_3, PROJECT_4
```

---

## Gotchas

| Issue | Cause | Fix |
|-------|-------|-----|
| `sudo: terminal required` | Running driver commands that need sudo without TTY | Run `sudo -v` first, or use `sudo systemctl ...` directly |
| LiteLLM `/health` returns 401 | Requires auth header | Use nginx `/health` on :4000 instead (no auth) |
| Model returns 429 | NVIDIA rate limit (20 RPM/key) | Wait, or ensure all 4 PROJECT keys are distinct |
| `myclaude` hangs on startup | Backend health check timeout (30s) | Check `journalctl -u myclaude -n 30`; usually missing API key |
| TLS cert errors with `curl` | Self-signed cert | Use `curl -k` or trust cert system-wide (see `driver.sh tls-enable`) |
| Port 4000/4001 already in use | Another service | `sudo ss -tlnp \| grep -E '4000\|4001'` |
| `nginx -t` fails | Config syntax or missing `limit_req_zone` in http block | Ensure `limit_req_zone` is in `/etc/nginx/nginx.conf` http context |

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `myclaude: command not found` | `source ~/.bashrc` or re-login |
| Backend won't start | `journalctl -u myclaude -n 30` — check for missing `.env` keys |
| Connection refused on :4000 | `sudo systemctl status nginx` — nginx may have failed |
| Slow responses | Reduce `max_tokens` in `config.yaml`; check NVIDIA NIM status |
| Only 1 model works | Other PROJECT keys not set (fallback to PROJECT_1) — set all 4 for isolation |
| Idle shutdown not working | Check `MYCLAUDE_IDLE_TIMEOUT` in `.env` (default 300s, 0 = disabled) |

---

## File Layout (from repo root)

```
/home/ML/myclaude/
├── install.sh                 # TUI installer
├── install-modular.sh         # Modular installer
├── install-modules/           # Modular install steps
├── config.yaml                # LiteLLM routing (4 models → Nemotron 3 Ultra)
├── nginx-myclaude.conf        # nginx template
├── litellm.service.template   # systemd unit template
├── setup-tls.sh               # TLS cert generator
├── test-models.sh             # Full model test suite
├── myclaude.sh                # Wrapper source → /usr/local/bin/myclaude
├── .env                       # API keys (gitignored)
├── .env.example               # Template
├── venv/                      # Python venv (created at install)
└── .claude/skills/run-myclaude/
    ├── SKILL.md               # This file
    └── driver.sh              # Interaction harness (committed here)
```

---

## Verification Checklist

After any change, run:

```bash
# 1. Health endpoints
./.claude/skills/run-myclaude/driver.sh health

# 2. All 4 models
./.claude/skills/run-myclaude/driver.sh test

# 3. Service status
./.claude/skills/run-myclaude/driver.sh status
```

All should pass with `[PASS]` / `[SUCCESS]`.