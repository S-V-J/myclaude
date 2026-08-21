# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

MyClaude is a local proxy stack that lets **Claude Code** use **NVIDIA NIM** models (Nemotron 3 Ultra) instead of Anthropic's API. It runs:

- **nginx** on port 4000 (HTTP) / 4443 (HTTPS) — rate limiting, TLS termination
- **LiteLLM** on port 4001 — format translation, model routing, NVIDIA NIM calls
- **systemd service** `myclaude` — manages both, with on-demand idle shutdown (5 min default)

All 4 Claude Code models route to the same Nemotron 3 Ultra backend with independent API keys for load isolation (80 RPM combined).

## Key Files

| File | Purpose |
|------|---------|
| `install.sh` | TUI installer (main entry, ~1200 lines) |
| `install-modular.sh` | Modular installer (calls modules in `install-modules/`) |
| `config.yaml` | LiteLLM routing config — 4 models → Nemotron 3 Ultra |
| `nginx-myclaude.conf` | nginx reverse proxy template |
| `litellm.service.template` | systemd unit template |
| `setup-tls.sh` | TLS/SSL certificate generator |
| `test-models.sh` | Full model test suite |
| `myclaude.sh` | Wrapper source → `/usr/local/bin/myclaude` |
| `.env` | API keys (gitignored, created by installer) |

## Common Commands

```bash
# Installation
make install           # Interactive TUI installer
make install-auto      # Automated (needs NVIDIA_API_KEY_PROJECT_1 env)
make reinstall         # Clean + install

# Service management
make status            # sudo systemctl status myclaude
make logs              # journalctl -u myclaude -f
make restart           # Restart service
make stop / make start # Stop/start service

# Testing
make test              # Test all 4 models + health endpoints
bash test-models.sh    # Same as make test

# Development
shellcheck install.sh myclaude.sh setup-tls.sh test-models.sh
yamllint config.yaml
sudo nginx -t
```

## Architecture

### Request Flow
```
Claude Code → nginx (4000/4443) → LiteLLM (4001) → NVIDIA NIM
```

1. **Claude Code** sends Anthropic Messages API format
2. **nginx** rate limits (16 req/s, burst 32), terminates TLS, forwards to LiteLLM
3. **LiteLLM** translates to OpenAI format, selects model via `least-busy` router, calls NVIDIA NIM
4. **NVIDIA NIM** streams SSE back through chain

### Model Routing (config.yaml)
All 4 models use `nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b` with different env vars:
- `claude-opus-5` → `NVIDIA_API_KEY_PROJECT_1` (required)
- `claude-sonnet-5` → `NVIDIA_API_KEY_PROJECT_2` (fallback to PROJECT_1)
- `claude-sonnet-5-1m` → `NVIDIA_API_KEY_PROJECT_3` (fallback to PROJECT_1)
- `claude-haiku-4-5` → `NVIDIA_API_KEY_PROJECT_4` (fallback to PROJECT_1)

### On-Demand Startup
The `myclaude` wrapper (`/usr/local/bin/myclaude`) auto-starts the backend when invoked and stops it after 5 minutes of inactivity (configurable via `MYCLAUDE_IDLE_TIMEOUT` in `.env`, 0 = always-on).

## Installer Modes

### Interactive TUI (default)
```bash
bash install.sh
```
4-step wizard: API Keys → Model Mapping → Advanced Options → Payload Validation

### Automated (--auto)
```bash
NVIDIA_API_KEY_PROJECT_1="..." bash install.sh --auto
# Optional: ENABLE_LAN, ENABLE_TLS, TLS_DOMAIN, NGINX_RATE, NGINX_BURST
```

## Testing

```bash
# Full test suite (health + all 4 models)
make test

# Individual model test
curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -X POST http://localhost:4000/v1/chat/completions \
  -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"test"}],"max_tokens":20}'
```

Health endpoints (no auth for nginx):
- `GET http://localhost:4000/health` — nginx
- `GET http://localhost:4001/health` — LiteLLM (requires auth)
- `GET https://localhost:4443/health` — TLS (if enabled)

## Gotchas

| Issue | Fix |
|-------|-----|
| `sudo: terminal required` | Run `sudo -v` first, or use `sudo systemctl ...` directly |
| LiteLLM `/health` returns 401 | Use nginx `/health` on :4000 instead (no auth) |
| Model returns 429 | NVIDIA rate limit (20 RPM/key) — wait or ensure all 4 PROJECT keys are distinct |
| `myclaude` hangs on startup | Backend health check timeout (30s) — check `journalctl -u myclaude -n 30` |
| TLS cert errors with `curl` | Use `curl -k` or trust cert system-wide |
| Port 4000/4001 already in use | `sudo ss -tlnp \| grep -E '4000\|4001'` |
| `nginx -t` fails | Ensure `limit_req_zone` is in `/etc/nginx/nginx.conf` http context |

## Skills

The repo includes a run skill at `.claude/skills/run-myclaude/`:
- `SKILL.md` — documentation
- `driver.sh` — programmatic harness (`./driver.sh start|stop|status|health|test|curl|logs|config|tls-enable|tls-disable`)

## Modifying the Stack

- **nginx config**: Edit `nginx-myclaude.conf`, then `sudo cp nginx-myclaude.conf /etc/nginx/sites-enabled/myclaude && sudo nginx -t && sudo systemctl reload nginx`
- **LiteLLM config**: Edit `config.yaml`, then `sudo systemctl restart myclaude`
- **TLS**: `sudo bash setup-tls.sh generate <domain> <enable_http>` or `sudo bash setup-tls.sh disable`
- **Environment**: Edit `.env`, then `sudo systemctl restart myclaude`

## Prerequisites for Development

- Ubuntu/Debian/WSL2 with systemd
- Python 3.10+, nginx, Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- NVIDIA NIM API keys from https://build.nvidia.com