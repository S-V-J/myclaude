#### Overview

MyClaude is a production-ready, smart launcher and proxy system for Claude Code that routes requests through **LiteLLM** with **NVIDIA NIM model integration**. It features a sophisticated **4-scenario fallback chain architecture** with **staggered API keys** for maximum reliability, **dynamic port assignment** to avoid conflicts, **security-hardened systemd services**, and **nginx reverse proxy with rate limiting**.

### Key Architecture Features

| Feature | Implementation |
|---------|----------------|
| **Model Provider** | NVIDIA NIM via LiteLLM proxy |
| **Fallback Strategy** | 4 scenarios × 5-model chains = 20 models total |
| **API Key Rotation** | Staggered across fallback chains (4 keys) |
| **Port Management** | Dynamic discovery at install/runtime (8000–50000) |
| **Process Management** | systemd with security hardening |
| **Reverse Proxy** | nginx with rate limiting (30r/m per-key, 16r/s global) |
| **TLS/SSL** | Let's Encrypt via certbot (optional) |
| **Installation** | True one-command: `git clone + sudo ./install.sh` |

---

## Sponsor Support

If you find this project useful, please consider sponsoring its development: [![Sponsor S-V-J](https://img.shields.io/badge/Sponsor%20on%20GitHub-Support%20this%20project-eb4aaa?style=for-the-badge&logo=github)](https://github.com/sponsors/S-V-J)

*Even a small contribution (e.g., $2) or a ⭐ star on this repository is highly appreciated. Thank you for believing in practical, open-source engineering!*

---

## Prerequisites

- **Root access** (sudo) for nginx, systemd, and system configuration
- **Python 3.8+** with `venv` module
- **nginx** with SSL module (for HTTPS)
- Standard Linux utilities: `curl`, `jq`, `procps`, `openssl`
- **Domain name** for HTTPS setup (optional, for `setup-tls.sh`)
- **NVIDIA API keys** (required — get from [build.nvidia.com](https://build.nvidia.com/))

---

## Installation

### One-Command Install (Recommended)

```bash
git clone https://github.com/S-V-J/myclaude.git ~/myclaude
cd ~/myclaude
sudo ./install.sh
```

That's it! The installation script **automatically**:
1. ✅ Installs all system dependencies (nginx, python3, certbot, etc.)
2. ✅ Discovers free ports to avoid conflicts (8000–50000 range)
3. ✅ Creates Python virtual environment and installs dependencies
4. ✅ Generates configuration with dynamic ports
5. ✅ Sets up systemd service for LiteLLM proxy with security hardening
6. ✅ Configures nginx reverse proxy with rate limiting
7. ✅ Installs logrotate configuration
8. ✅ Starts all services
9. ✅ Verifies health endpoints

**After installation completes:**
1. Edit `~/myclaude/.env` and replace placeholder NVIDIA API keys with your actual keys
2. Run: `sudo systemctl restart myclaude`
3. Test with: `myclaude`

### Install with Options

```bash
# Custom directory and service user
sudo ./install.sh --dir /opt/myclaude --user myclaude

# With HTTPS (Let's Encrypt)
sudo ./install.sh --https --domain api.example.com

# Skip dependency installation (if already installed)
sudo ./install.sh --no-deps

# Combine options
sudo ./install.sh --dir /opt/myclaude --user myclaude --https --domain api.example.com
```

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MYCLAUDE_INSTALL_DIR` | `$HOME/myclaude` | Installation directory |
| `MYCLAUDE_SERVICE_USER` | Current user | Service user for systemd |
| `MYCLAUDE_ENABLE_HTTPS` | `false` | Enable HTTPS/TLS |
| `MYCLAUDE_TLS_DOMAIN` | — | TLS domain name |
| `MYCLAUDE_AUTO_INSTALL_DEPS` | `true` | Auto-install system dependencies |

### Installation Script Details (`install.sh`)

The `install.sh` script (443 lines) is the **complete automation engine**. Key functions:

| Function | Purpose |
|----------|---------|
| `parse_args()` | Handles CLI flags and environment variables |
| `check_root()` | Enforces sudo execution |
| `install_dependencies()` | Installs nginx, python3, certbot, etc. via apt |
| `check_existing_installation()` | Warns if target directory not empty |
| `create_directories()` | Creates install dir, venv, logs, nginx log dir |
| `discover_ports()` | Finds free ports using `ss -tuln` (8000–50000) |
| `install_python_deps()` | Creates venv, upgrades pip, installs requirements.txt |
| `generate_env_file()` | Creates `.env` with ports, master key, placeholder NVIDIA keys |
| `build_config()` | Runs `build_config.sh` to generate `config.yaml` |
| `install_systemd_service()` | Creates `/etc/systemd/system/myclaude.service` |
| `install_nginx_config()` | Processes `nginx-myclaude.conf` with `sed`, adds rate limit zone |
| `install_logrotate()` | Processes `logrotate-myclaude` template |
| `setup_https()` | Runs certbot, updates nginx for HTTPS |
| `install_launcher()` | Copies `myclaude.sh` to `/usr/local/bin/myclaude` |
| `set_permissions()` | Secure permissions (750 dir, 640 .env, etc.) |
| `start_services()` | Enables and starts myclaude + nginx |
| `verify_installation()` | Health checks on nginx and LiteLLM endpoints |
| `print_summary()` | Shows ports, next steps, useful commands |

**Port Discovery Algorithm:**
- Nginx: First free port 8000–50000
- LiteLLM: Nginx port + 1 (or next free)
- HTTPS: First free port 8443–50000 (if enabled)

---

## Core System Files

### 1. `myclaude.sh` — Smart Launcher & Runtime Manager (170 lines)

The **primary user-facing script** installed at `/usr/local/bin/myclaude`. It handles the complete runtime lifecycle.

#### Commands
```bash
myclaude              # Start (default)
myclaude --restart    # Restart services
myclaude status       # Show service status
myclaude stop         # Stop services
```

#### Start Flow (`start` command)
1. **Startup lock** — Prevents concurrent launches (`/tmp/myclaude_startup.lock`)
2. **Cleanup** — Removes stale port/PID files (`/tmp/myclaude_ports.env`, `/tmp/myclaude_pid`)
3. **Config rebuild** — Runs `build_config.sh` to regenerate `config.yaml`
4. **Dynamic port allocation** — Python script binds to port 0 to get free ports:
   ```python
   s = socket.socket(); s.bind(('', 0)); port = s.getsockname()[1]; s.close()
   ```
   Writes to `/tmp/myclaude_ports.env` (NGINX_PORT, LITELLM_PORT, HTTPS_PORT)
5. **Systemd update** — `sed` updates `ExecStart` port in `/etc/systemd/system/myclaude.service`
6. **Nginx config generation** — `sed` replaces `__NGINX_PORT__` and `__LITELLM_PORT__` in template
7. **Nginx test & reload** — `nginx -t && systemctl reload nginx`
8. **Service restart** — `systemctl daemon-reload && systemctl restart myclaude`
9. **Health verification** — Checks nginx `/health` and LiteLLM `/health/litellm`
10. **Launch Claude Code** — `exec claude "$@"` (passes all args to Claude Code)

#### Key Features
- **Auto-recovery**: Monitors service health, restarts on failure
- **Idle timeout**: Configurable via `IDLE_TIMEOUT` in `.env` (0 = always on)
- **Port file synchronization**: Reads/writes `/tmp/myclaude_ports.env` for dynamic ports
- **Lock protection**: Prevents multiple simultaneous startups

---

### 2. `build_config.sh` — Configuration Builder (15 lines)

Concatenates modular YAML files into the final `config.yaml` for LiteLLM:

```bash
cat config_base.yaml > config.yaml
cat models/scene_1_default.yaml >> config.yaml
cat models/scene_2_opus_1m.yaml >> config.yaml
cat models/scene_3_sonnet.yaml >> config.yaml
cat models/scene_4_sonnet_1m.yaml >> config.yaml
```

**Output:** Single `config.yaml` with 4 complete model scenarios.

---

### 3. `config_base.yaml` — Base LiteLLM Configuration

Core LiteLLM settings applied to all scenarios:

```yaml
general_settings:
  routing_strategy: "simple-shuffle"
  litellm_proxy_timeout: 3600
  litellm_proxy_max_request_timeout: 3600
  master_key: ${LITELLM_MASTER_KEY}
  use_chat_completions_url_for_anthropic_messages: true
  drop_params: true
  add_function_to_prompt: true

router_settings:
  routing_strategy: "simple-shuffle"
  retry_policy:
    max_retries: 2
    retry_on_status_codes: [429, 500, 502, 503, 504]
  health_check:
    enabled: true
    interval: 30
    path: "/health"
  load_balancing:
    strategy: "round_robin"
```

---

### 4. Four Scene Configuration Files (`models/` directory)

Each scene defines a **5-model fallback chain** with **staggered API key usage**. The staggering ensures that if one key hits rate limits, other scenarios can still operate.

#### Scene 1: Default (`scene_1_default.yaml`)
- **Primary model**: `claude-opus-5`
- **Fallback chain**: Ultra → Super → Nano → Laguna → Ultra
- **API key order**: 1 → 2 → 3 → 4 → 1

#### Scene 2: Opus 1M (`scene_2_opus_1m.yaml`)
- **Primary model**: `claude-3-opus-20240229` + `claude-opus-5-1m`
- **Fallback chain**: Ultra → Super → Nano → Laguna → Ultra
- **API key order**: 2 → 3 → 4 → 1 → 2

#### Scene 3: Sonnet (`scene_3_sonnet.yaml`)
- **Primary model**: `claude-sonnet-5`
- **Fallback chain**: Ultra → Super → Nano → Laguna → Ultra
- **API key order**: 3 → 4 → 1 → 2 → 3

#### Scene 4: Sonnet 1M (`scene_4_sonnet_1m.yaml`)
- **Primary model**: `claude-sonnet-5-1m`
- **Fallback chain**: Ultra → Super → Nano → Laguna → Ultra
- **API key order**: 4 → 1 → 2 → 3 → 4

#### Models in Each Fallback Chain (in order)
| Position | Model ID | Description |
|----------|----------|-------------|
| 1 (Ultra) | `nvidia/nemotron-3-ultra-550b-a55b` | Largest, most capable |
| 2 (Super) | `nvidia/nemotron-3-super-120b-a12b` | Large, high quality |
| 3 (Nano) | `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning` | Reasoning-optimized |
| 4 (Laguna) | `poolside/laguna-xs-2.1` | Efficient coding model |
| 5 (Ultra) | `nvidia/nemotron-3-ultra-550b-a55b` | Ultra again as final fallback |

#### Staggered API Key Pattern
```
Scene 1: Key1 → Key2 → Key3 → Key4 → Key1
Scene 2: Key2 → Key3 → Key4 → Key1 → Key2
Scene 3: Key3 → Key4 → Key1 → Key2 → Key3
Scene 4: Key4 → Key1 → Key2 → Key3 → Key4
```

**Why this matters:** If Key1 hits rate limits, Scene 1 falls back to Keys 2-4, while Scenes 2-4 start with different keys, distributing load across all 4 keys.

---

### 5. `nginx-myclaude.conf` — Nginx Reverse Proxy Template

Processed by `install.sh` with `sed` to inject dynamic ports. Key features:

#### Upstream Configuration
```nginx
upstream litellm_backend {
    server 127.0.0.1:__LITELLM_PORT__ max_fails=3 fail_timeout=30s;
    keepalive 32;
    keepalive_requests 1000;
    keepalive_timeout 60s;
}
```

#### Security Headers (Applied to All Responses)
```nginx
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header Referrer-Policy strict-origin-when-cross-origin always;
```

#### Rate Limiting
```nginx
# Global rate limit (added to nginx.conf http block by install.sh)
limit_req_zone $binary_remote_addr zone=myclaude:10m rate=16r/s;

# Per-request rate limit (in location /)
limit_req zone=myclaude burst=32 nodelay;
limit_req_status 503;
limit_req_log_level warn;
```

**Note:** The `myclaude.sh` startup also adds **per-API-key rate limiting** by using the `Authorization` header as the limit key, achieving ~30 requests/minute per key.

#### Endpoints
| Path | Rate Limit | Auth | Purpose |
|------|------------|------|---------|
| `/` | Yes (16r/s global + 30r/m per-key) | Via LiteLLM | Main proxy traffic |
| `/health` | No | No | Nginx health check |
| `/health/litellm` | No | No | LiteLLM health (proxied) |
| `/metrics` | No | IP allowlist | Prometheus metrics |
| `/admin/*`, `/config/*`, `/models/*`, `/keys/*` | N/A | Denied | Admin path blocking |

#### HTTPS Server Block (Commented, Enabled by `setup-tls.sh`)
- TLS 1.2/1.3 only
- Modern cipher suites
- OCSP Stapling
- HSTS header
- Same rate limiting and security headers

---

### 6. `.env` — Environment Configuration

Generated by `install.sh` with dynamic ports and a random master key:

```bash
# NVIDIA API Keys (REQUIRED - replace placeholders)
NVIDIA_API_KEY_1="nvapi-placeholder-replace-with-your-key-1"
NVIDIA_API_KEY_2="nvapi-placeholder-replace-with-your-key-2"
NVIDIA_API_KEY_3="nvapi-placeholder-replace-with-your-key-3"
NVIDIA_API_KEY_4="nvapi-placeholder-replace-with-your-key-4"

# LiteLLM Master Key (auto-generated)
LITELLM_MASTER_KEY="sk-local-<random-hex>"

# LiteLLM Settings
LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="true"

# Idle Timeout (0 = always on, seconds otherwise)
IDLE_TIMEOUT="0"

# Dynamic ports (auto-discovered, do not edit manually)
LITELLM_PORT=<discovered>
NGINX_PORT=<discovered>
HTTPS_PORT=<discovered-or-empty>
```

**Critical:** After installation, you **must** edit this file and replace all 4 placeholder NVIDIA API keys with actual keys from [build.nvidia.com](https://build.nvidia.com/).

---

### 7. `setup-tls.sh` — Let's Encrypt TLS Setup

Enables HTTPS with automatic certificate management:

```bash
sudo ./setup-tls.sh --domain yourdomain.com
```

**Features:**
- Validates domain resolves to server IP
- Obtains/renews certificates via certbot
- Updates nginx config with SSL settings
- Configures OCSP stapling, HSTS, modern TLS
- Sets up auto-renewal via systemd timer
- Reads ports from `.env` (dynamic, not hardcoded)

---

### 8. `uninstall.sh` — Complete Removal

Safely removes all traces of MyClaude:

```bash
sudo ./uninstall.sh
```

**Removes:**
- systemd service (`/etc/systemd/system/myclaude.service`)
- nginx site configs (available/enabled)
- logrotate config (`/etc/logrotate.d/myclaude`)
- Launcher (`/usr/local/bin/myclaude`)
- nginx rate limit zone from `nginx.conf`
- Installation directory (with confirmation)

---

### 9. `logrotate-myclaude` — Log Rotation Template

Processed by `install.sh` with `sed` (`__REPO_DIR__`, `__SERVICE_USER__`):

```nginx
__REPO_DIR__/logs/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 __SERVICE_USER__ __SERVICE_USER__
    sharedscripts
    postrotate
        systemctl reload myclaude > /dev/null 2>&1 || true
    endscript
}

/var/log/nginx/myclaude-*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 www-data www-data
    sharedscripts
    postrotate
        systemctl reload nginx > /dev/null 2>&1 || true
    endscript
}
```

---

### 10. `utils/backup.sh` — Backup & Recovery Utility

**Backup:**
```bash
./utils/backup.sh                          # Config only
./utils/backup.sh --include-logs           # Config + logs
./utils/backup.sh --backup-dir /mnt/backups # Custom location
```

**Restore:**
```bash
sudo ./utils/backup.sh restore /path/to/backup.tar.gz
```

**List:**
```bash
./utils/backup.sh list
```

**What's Backed Up:**
- All config files: `.env`, `config.yaml`, `config_base.yaml`, `requirements.txt`, `models/`, `nginx-myclaude.conf`, `logrotate-myclaude`, `myclaude.sh`, `build_config.sh`, `litellm.service.template`, `setup-tls.sh`
- System configs (if run as root): `/etc/systemd/system/myclaude.service`, `/etc/nginx/sites-available/myclaude`, `/etc/nginx/sites-enabled/myclaude`, `/etc/logrotate.d/myclaude`, `/usr/local/bin/myclaude`
- Application logs (optional via `--include-logs`)
- Manifest file (`MANIFEST.txt`) with complete file listing

---

### 11. `utils/status.sh` — Status & Health Check Utility

```bash
./utils/status.sh              # Basic status
./utils/status.sh --live       # Live log view
./utils/status.sh --repo-dir /opt/myclaude  # Custom install dir
```

**Checks Performed:**
- Service status: `myclaude`, `nginx` (systemctl)
- Nginx site enabled: `/etc/nginx/sites-enabled/myclaude`
- Port listening: Reads `NGINX_PORT`, `LITELLM_PORT`, `HTTPS_PORT` from `.env`
- Health endpoints: `http://localhost:NGINX_PORT/health`, `http://localhost:LITELLM_PORT/health/litellm`, `http://localhost:LITELLM_PORT/health` (with master key)
- Config file existence: `.env`, `config.yaml`, `requirements.txt`
- Recent logs (last 10 lines): `logs/litellm.log`, `journalctl -u myclaude`

---

### 12. `git_push.sh` / `git_setup.sh` — Git Helpers

| Script | Purpose |
|--------|---------|
| `git_setup.sh` | Configures git user, remote, pushes to GitHub |
| `git_push.sh` | Commits and pushes with conventional commit messages |

---

### 13. `requirements.txt` — Python Dependencies

```
litellm[proxy]>=1.96.0
python-dotenv>=1.0.0
```

---

### 14. `litellm.service.template` — Alternative Systemd Template

Alternative service definition (not used by default `install.sh`):

```ini
[Unit]
Description=LiteLLM Proxy Server
After=network.target

[Service]
Type=simple
User=myclaude
WorkingDirectory=/home/myclaude/myclaude
Environment=PATH=/home/myclaude/myclaude/venv/bin
EnvironmentFile=/home/myclaude/myclaude/.env
ExecStart=/home/myclaude/myclaude/venv/bin/litellm --config /home/myclaude/myclaude/config.yaml --port 4000 --host 0.0.0.0
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
```

---

## Usage

### Basic Usage

```bash
# Launch MyClaude proxy (starts services if needed, then runs Claude Code)
myclaude

# Launch with specific model
myclaude --model claude-sonnet-5

# Any Claude Code arguments are passed through
myclaude --help
myclaude --version
```

### Service Management

```bash
# Check service status
sudo systemctl status myclaude

# View service logs (follow)
sudo journalctl -u myclaude -f

# Check MyClaude status (reads dynamic ports from .env)
./utils/status.sh

# View application logs
tail -f ~/myclaude/logs/litellm.log

# Restart services
sudo systemctl restart myclaude nginx

# Stop services
myclaude stop
# or
sudo systemctl stop myclaude nginx
```

### Configuration Management

```bash
# Rebuild config.yaml after editing scene files
./build_config.sh

# Edit NVIDIA API keys
nano ~/myclaude/.env
# Then restart:
sudo systemctl restart myclaude

# Enable HTTPS
sudo ./setup-tls.sh --domain api.example.com
```

### Backup & Recovery

```bash
# Create backup
./utils/backup.sh --include-logs --backup-dir /mnt/backups

# List backups
./utils/backup.sh list

# Restore backup
sudo ./utils/backup.sh restore /mnt/backups/myclaude-backup-20240128_123456.tar.gz
```

---

## Advanced Configuration

### NVIDIA API Keys Setup

1. Go to [build.nvidia.com](https://build.nvidia.com/)
2. Create account / sign in
3. Generate API keys (need 4 keys for full fallback coverage)
4. Edit `~/myclaude/.env`:
   ```bash
   NVIDIA_API_KEY_1="nvapi-your-first-key"
   NVIDIA_API_KEY_2="nvapi-your-second-key"
   NVIDIA_API_KEY_3="nvapi-your-third-key"
   NVIDIA_API_KEY_4="nvapi-your-fourth-key"
   ```
5. Restart: `sudo systemctl restart myclaude`

### Idle Timeout

Set `IDLE_TIMEOUT` in `.env` (seconds):
```bash
IDLE_TIMEOUT="3600"  # Shut down after 1 hour of inactivity
IDLE_TIMEOUT="0"     # Always on (default)
```

### Custom Nginx Tuning

The `install.sh` applies these optimizations to `/etc/nginx/nginx.conf`:
```nginx
worker_processes 1;
worker_connections 1024;
keepalive_timeout 30s;
client_body_buffer_size 64k;
client_header_buffer_size 512;
```

---

## Troubleshooting

### Services Won't Start
```bash
# Check systemd status
sudo systemctl status myclaude
sudo systemctl status nginx

# Check logs
sudo journalctl -u myclaude -n 50
sudo journalctl -u nginx -n 50

# Check port conflicts
ss -tuln | grep -E ':(8000|8001|8443)'
```

### Health Checks Failing
```bash
# Test nginx health
curl http://localhost:$(grep NGINX_PORT ~/myclaude/.env | cut -d= -f2)/health

# Test LiteLLM health
MASTER_KEY=$(grep LITELLM_MASTER_KEY ~/myclaude/.env | cut -d= -f2)
curl -H "Authorization: Bearer $MASTER_KEY" http://localhost:$(grep LITELLM_PORT ~/myclaude/.env | cut -d= -f2)/health
```

### NVIDIA API Key Issues
- Verify keys are valid at [build.nvidia.com](https://build.nvidia.com/)
- Check all 4 keys are set in `.env`
- Ensure keys have access to Nemotron models
- Check LiteLLM logs for auth errors: `tail -f ~/myclaude/logs/litellm.log`

### Port Conflicts
```bash
# Find what's using a port
ss -tulpn | grep :<PORT>

# Re-run install to pick new ports
sudo ./install.sh --no-deps
```

---

## Repository URLs

- **HTTPS**: https://github.com/S-V-J/myclaude.git
- **SSH**: git@github.com:S-V-J/myclaude.git
- **GitHub CLI**: `gh repo clone S-V-J/myclaude`

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        User / Claude Code                           │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    myclaude.sh (launcher)                           │
│  • Startup lock • Port discovery • Config rebuild                  │
│  • systemd update • nginx config • Health checks                   │
│  • Auto-recovery • Idle timeout • exec claude                      │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
        ┌───────────────────┐         ┌───────────────────┐
        │    nginx          │         │    systemd        │
        │  (reverse proxy)  │         │  (LiteLLM proxy)  │
        │  Port: NGINX_PORT │         │  Port: LITELLM_P. │
        └─────────┬─────────┘         └─────────┬─────────┘
                  │                             │
                  │ Rate limiting               │
                  │ 16r/s global                │
                  │ 30r/m per API key           │
                  ▼                             ▼
        ┌───────────────────┐         ┌───────────────────┐
        │  /health          │         │  LiteLLM Proxy    │
        │  /health/litellm  │         │  config.yaml      │
        │  /metrics         │         │  4 scenarios ×    │
        │  Admin blocking   │         │  5-model chains   │
        └───────────────────┘         └─────────┬─────────┘
                                                │
                    ┌───────────────────────────┼───────────────────────────┐
                    ▼                           ▼                           ▼
           ┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
           │ Scene 1: Default│         │ Scene 2: Opus   │         │ Scene 3: Sonnet │
           │ claude-opus-5   │         │ 1M              │         │                 │
           │ Key1→2→3→4→1    │         │ Key2→3→4→1→2    │         │ Key3→4→1→2→3    │
           └────────┬────────┘         └────────┴────────┘         └────────┴────────┘
                    │                           │                           │
           ┌────────┴────────┐         ┌────────┴────────┐         ┌────────┴────────┐
           │ 5-Model Chain   │         │ 5-Model Chain   │         │ 5-Model Chain   │
           │ Ultra→Super→    │         │ Ultra→Super→    │         │ Ultra→Super→    │
           │ Nano→Laguna→    │         │ Nano→Laguna→    │         │ Nano→Laguna→    │
           │ Ultra           │         │ Ultra           │         │ Ultra           │
           └─────────────────┘         └─────────────────┘         └─────────────────┘
                    │                           │                           │
                    └───────────────────────────┼───────────────────────────┘
                                                ▼
                                    ┌─────────────────────────┐
                                    │   NVIDIA NIM API        │
                                    │   (Nemotron 3 Ultra,    │
                                    │   Super, Nano, Laguna)  │
                                    └─────────────────────────┘
```

---

## Security Features

| Layer | Implementation |
|-------|----------------|
| **systemd** | `NoNewPrivileges=true`, `PrivateTmp=true`, `ProtectSystem=strict`, `ProtectHome=read-only`, `ReadWritePaths=logs` |
| **nginx** | Security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy), admin path blocking, IP-restricted metrics |
| **Rate Limiting** | Global 16r/s + per-API-key 30r/m (via nginx map on Authorization header) |
| **File Permissions** | `.env` = 640, install dir = 750, owned by service user |
| **TLS** | TLS 1.2/1.3 only, modern ciphers, HSTS, OCSP stapling (when enabled) |

## About the Creator

### Siddhant Kumar
**Full-Stack Developer | VoIP & Telephony Engineer | AI Developer | Technical Support**  
📞 +91 8095875948  |  ✉️ stjl093@gmail.com  |  📍 Bihar, India  
🔗 **GitHub**: [github.com/S-V-J](https://github.com/S-V-J)  |  **LinkedIn**: [linkedin.com/in/sid-093](https://linkedin.com/in/sid-093)  
✅ **Available for global remote roles**  |  **Full-time (up to 40 hrs/week)**  
*Employment, education, and certificates verifiable at LinkedIn*

#### Professional Summary
With **5+ years** of professional experience in telecom operations and enterprise technical support, and **1+ years** of intensive full-stack, VoIP, and AI development through successfully delivered contracts for clients in **Switzerland, Germany, and India**. Deep domain expertise in telephony infrastructure from **TELUS Digital** (Canada's largest telecom provider), now applied to building production-grade systems — from Asterisk/Kamailio PBX configuration and Python/FastAPI backends to React frontends, LLM-powered AI pipelines, and cloud deployment. Published researcher, active open-source developer, and contributor to AI model training and evaluation. Available immediately for remote roles, up to 40 hours/week.

#### Open to Global Remote Roles
- **Software Engineering**: Full-Stack Developer | Backend Engineer
- **AI & Automation**: AI System Developer | Chat + Voice AI Bot Developer
- **AI Trainer**: AI Model Trainer / AI Training Task / AI Evaluator
- **Infrastructure & Networks**: DevOps / Platform Engineer | VoIP Engineer | Network Engineer
- **Operations & Support**: Technical Support | Desktop Support | Helpdesk Engineer

#### Technical Skills
| Category | Technologies |
|----------|-------------|
| **VoIP & Telephony** | Asterisk, Kamailio \| SIP, ISUP, RTP/RTCP \| Telephony Switches & Trunking \| .pcap Analysis |
| **Languages** | Python (primary), C, C++, JavaScript, TypeScript, Java, Bash scripting |
| **Backend** | FastAPI, Flask, Django \| Node.js / Express.js \| Spring Boot 3.2 (Java) |
| **Frontend** | React 18, Next.js, Vue.js, HTML5, CSS3, Tailwind CSS |
| **AI & LLM** | LLM APIs & Local Deployment \| Agentic Orchestration \| Model Fine-Tuning & Evaluation \| Classical ML (LightGBM, Scikit-Learn) |
| **Databases** | PostgreSQL, MySQL, MongoDB, Redis, Elasticsearch |
| **Cloud & Infrastructure** | AWS (EC2, S3, Lambda, VPC), Hetzner Cloud, Linux Ubuntu / RHEL, Nginx, systemd |
| **DevOps** | Docker, Kubernetes, Terraform, Ansible, GitHub Actions, GitLab CI/CD |
| **Tools & CRM** | Git, Wireshark, ServiceNow, Lynx, SAP, MSD 365, TeamViewer, AnyDesk, Rescue, Outlook, Excel |
| **Languages Spoken** | English (C1+ Professional — B2C and B2B including Canadian clients) \| Hindi (Native) |

#### Professional Experience

**Full-Time Employment**

**Network Associate** \| **TELUS Digital** — Canada  \|  *Jan 2022 – Aug 2025 (3 yrs 8 months)*  \|  Remote  
- Command-based programming, testing, and troubleshooting of telephony switches GTD 5 and DMS 100 — maintaining enterprise telephony infrastructure for Canada's largest telecom provider.  
- Resolved SIP and ISUP call-related issues and SIP trunking service problems — call tracing and .pcap file analysis using IRIS, CGIS, and Wireshark to diagnose protocol-level failures.  
- CRM management with Lynx and ServiceNow — full incident lifecycle, escalation, RCA documentation, and professional English communication with Canadian business clients (B2B).  
- Remote role: softphone-based calls, Outlook for client email, Excel for tracking and data entry.

**Technical Support Advisor I** \| **Concentrix**  \|  *Feb 2021 – Oct 2021 (9 months)*  \|  Office + Remote  
- Technical support for laptops and desktops — hardware faults (RAM, HDD, display, keyboard, power supply) and inbuilt software issues (OS, drivers, applications) for consumer and enterprise customers.  
- Remote access tools: Rescue, TeamViewer, AnyDesk — full remote device control for live diagnosis and repair.  
- CRM: SAP and MSD — case logging, escalation, and resolution documentation.  
- On-call 9-hour shifts in professional English and Hindi; B2C support via both soft and hard phones; Outlook for email; Excel for data entry and call reporting.

**Contract Engagements**

**VoIP AI Integration Engineer** \| **Basal Analytics Pvt. Ltd** (desible.ai)  \|  *Dec 2025 — 30-day delivery*  
- Configured Asterisk PBX with the AudioSocket module and wrote a Python WebSocket client bridging live calls to Desible AI's voice AI engine — enabling real-time AI handling of answered outbound calls.  
- Architecture: outbound calls originated by partner company, routed to this Asterisk endpoint; calls transferred to AI on answer — full end-to-end outbound AI call pipeline.  
- Deployed and configured on AWS EC2 (Linux Ubuntu); SIP trunk setup for call origination partner.  
- Stack: Asterisk, AudioSocket, Python, WebSocket, SIP trunk, AWS EC2, Linux Ubuntu, Kamailio

**AI Backend Developer** \| **Raiva** — Germany (raiva.io)  \|  *Oct 2025 – Jan 2026 (4 months)*  
- Built a document indexing and search portal enabling users to query large document repositories by both text input and real-time voice — semantic NLP search with conversational AI responses and live voice chat.  
- Integrated OpenAI API for NLU query processing, Whisper for voice-to-text, and real-time conversational AI for document-grounded dialogue.  
- Deployed on Hetzner Cloud (Linux Ubuntu); REST API backend with web portal frontend.  
- Stack: Python, OpenAI API, Linux Ubuntu, Hetzner Cloud, document indexing, semantic search, REST API, Conversational AI, real-time voice, PostgreSQL

**VoIP Engineer** \| **Lancelot Technology** (lancelotech.com)  \|  *Aug – Sep 2025 — 45-day delivery*  
- Configured Asterisk and Kamailio PBX across two separate Ubuntu servers with a custom admin panel for complete PBX management — extension provisioning, call routing, tenant management.  
- Designed and implemented multilingual IVR with voice and language detection and voice prompt playback for intelligent caller input routing.  
- Configured SIP trunks on both servers; full project delivered within 45 days.  
- Stack: Asterisk, Kamailio, Linux Ubuntu (2 servers), SIP trunk, IVR, voice prompt, language detection, Python, Bash, admin panel development

**VoIP & PBX Engineer** \| **IWALINK SA** — Switzerland  \|  *May – Jun 2025 — 51-day delivery*  
- Configured Asterisk PBX on hosted hard server — softphone login, inbound/outbound calls, voicemail, IVR system, and SIP trunk integration delivered from scratch.  
- Wrote Bash automation scripts and Python AGI (Asterisk Gateway Interface) programs for dynamic call routing logic and IVR intelligence.  
- Developed an admin panel for ongoing PBX management — extension control, call routing, SIP trunk status, IVR menu editing.  
- Stack: Asterisk, SIP trunk, IVR, AGI (Python), Bash scripting, Linux Ubuntu, .conf file management, softphone, voicemail, admin panel (Python/web)

#### Personal Projects (GitHub: [github.com/S-V-J](https://github.com/S-V-J))

| Project | Description | Stack |
|---------|-------------|-------|
| **[MyClaude](https://github.com/S-V-J/myclaude)** | Smart launcher and proxy system for Claude Code using LiteLLM with NVIDIA NIM model integration | LiteLLM, NVIDIA NIM, systemd, nginx, Python, Bash |
| **[sasyashri](https://github.com/S-V-J/sasyashri)** | Personal portfolio and projects showcase | HTML, CSS, JavaScript |
| **[CommBank-Server](https://github.com/S-V-J/CommBank-Server)** | Fork of CommBank tech stack from Forage job simulation - for debugging purposes | Java, Spring Boot |
| **[ominivoice](https://github.com/S-V-J/ominivoice)** | Advanced Multilingual Voice Agent Platform with Real-time Translation capabilities | Python, VAPI, Twilio, WebRTC |
| **[voice-agent](https://github.com/S-V-J/voice-agent)** | AI-powered outbound sales agent with VAPI, Twilio, and retell.ai integrations for cold calling | Python, VAPI, Twilio, retell.ai |
| **[premura-app](https://github.com/S-V-J/premura-app)** | Healthcare appointment and patient management system | React, Node.js, MongoDB |
| **[fuelroute-pro](https://github.com/S-V-J/fuelroute-pro)** | AI-powered fuel route optimization and cost savings platform for logistics | Python, OR-Tools, FastAPI, React |
| **[mycode](https://github.com/S-V-J/mycode)** | Personal code snippets, utilities, and learning projects | Python, JavaScript, Bash |
| **[premura-corp-live-build](https://github.com/S-V-J/premura-corp-live-build)** | Corporate live build and deployment pipeline automation | Jenkins, Docker, Kubernetes |
| **[premura-ssh-test](https://github.com/S-V-J/premura-ssh-test)** | SSH automation and testing utilities for server management | Bash, Python, Paramiko |
| **[Spotter Universal ML Platform](https://github.com/S-V-J/spotter-freight-rate-ml)** | Freight rate prediction and optimization system using LightGBM regressor on ~48K records | LightGBM, FastAPI, Next.js, Docker |
| **[NexusHub](https://github.com/S-V-J/nexushub)** | All-in-one personal web hub: link-in-bio, URL shortener, todos, habits, code snippets, polls, feedback | Next.js, Supabase, Tailwind CSS |
| **[Universal E-Commerce System](https://github.com/S-V-J/ecom_web_app)** | Adaptable platform for online stores with product catalog, cart, and checkout flows | React, FastAPI, PostgreSQL |
| **[CRM Self-Healer](https://github.com/S-V-J/crm-self-healer)** | Automated CRM data synchronization and repair system for GoHighLevel with self-healing capabilities | n8n, FastAPI, Ollama, pytest |
| **[practice-live-build](https://github.com/S-V-J/practice-live-build)** | Live coding practice platform with real-time collaboration and feedback | React, Socket.io, Node.js |
| **[zero2hero](https://github.com/S-V-J/zero2hero)** | Comprehensive full-stack development course with 10 production projects from scratch | Linux, C/C++, Python, AI/ML, Asterisk, Kamailio, DevSecOps |
| **[AetherAgent](https://github.com/S-V-J/AetherAgent)** | Fully local AI agent on Linux with no context limits, 100% prompt-faithful decoder-only transformer | PyTorch, LoRA, SSE, Hugging Face |
| **[devops](https://github.com/S-V-J/devops)** | DevOps UI Management Platform with Spring Boot 3.2 + React 18, fine-grained RBAC, JWT, Swagger, GitHub Actions CI/CD | Spring Boot, React, Docker, Kubernetes |
| **[PBX-Platform](https://github.com/S-V-J/PBX-Platform)** | Enterprise multi-tenant PBX platform: Asterisk + Kamailio + Python/FastAPI + PostgreSQL — 12 microservices, 76-table schema | Asterisk, Kamailio, FastAPI, PostgreSQL, Python |
| **[CloudDevStudio](https://github.com/S-V-J/CloudDevStudio)** | Self-hosted web-based Linux development platform: browser IDE, terminal, AI coding assistance, database tooling | Next.js, Docker, Linux, Theia |

#### Internships
- **Renesas RL78 Microcontroller** \| SM Electronic Technologies Pvt. Ltd, Bangalore  \|  *Jan 2020 – Apr 2020* — Certificate issued Nov 3, 2020
- **C Programming and Embedded Systems** \| Acharya Institute of Technology (ECE Dept), Bangalore  \|  *Jan 16–31, 2017* — USN: 1AY15EC093

#### Research Publication
**Intelligent Line Follower Robot using MSP430G2ET for Industrial Applications**  
Journal: *Helix — The Scientific Explorer*, Vol. 10 (2): pp. 232–237, Apr 2020  
DOI: [doi.org/10.29042/2020-10-2-232-237](https://doi.org/10.29042/2020-10-2-232-237)  
Authors: Sourav Sutradhar, Viswanatha V, **Siddhant Kumar**, Shivam Kumar — Acharya Institute of Technology, Bangalore  
Presented at: AICTE-Sponsored ISCCS 2019, Sree Vidyanikethan Engineering College, Tirupati, AP — 17–19 Oct 2019

#### Education
| Degree | Institution | Completed |
|--------|-------------|-----------|
| **BE — Electronics & Communication Engineering** (Second Class) | Visvesvaraya Technological University (VTU), Belagavi, Karnataka | Jan 2023 |
| **12th Board — Science (PCM)** (First Class) | Bihar School Examination Board (BSEB) | Apr 2015 |
| **10th Board — CBSE** (First Class) | Central Board of Secondary Education (CBSE) | May 2013 |

#### Certifications
| Certification | Issuer | Date | Link |
|---------------|--------|------|------|
| 2024 Bootcamp: Generative AI + LLM App Development | Udemy (Julio Colomer) | Sep 2024 — 61 hrs | [Verify](https://www.udemy.com/certificate/) |
| Introduction to Cybersecurity | Cisco | Mar 2024 | [Verify](https://www.cisco.com/) |
| Getting Started with Cisco Packet Tracer | Cisco Networking Academy | 2024 | [Verify](https://www.netacad.com/) |
| Pointers, Arrays, and Recursion | Duke University (Coursera) | Dec 2020 | [Verify](https://www.coursera.org/) |
| The Bits and Bytes of Computer Networking | Google (Coursera) | Jul 2020 — 21 hrs | [Verify](https://www.coursera.org/) |
| Writing, Running, and Fixing Code in C | Duke University (Coursera) | Jun 2020 — 20 hrs | [Verify](https://www.coursera.org/) |
| Technical Support Fundamentals | Google (Coursera) | May 2020 — 19 hrs | [Verify](https://www.coursera.org/) |
| Programming Fundamentals | Duke University (Coursera) | May 2020 — 18 hrs | [Verify](https://www.coursera.org/) |
| C Programming and Embedded Systems | Acharya Institute of Technology (ECE) | Jan 2017 | — |
| Conference Paper Presentation — ISCCS 2019 | AICTE-Sponsored International Conference | Oct 2019 | [Verify](https://www.aicte-india.org/) |
| Introduction to Software Engineering Job Simulation | Commonwealth Bank (Forage) | Sep 1, 2026 | [Verify](https://www.theforage.com/) |
| Software Engineering Job Simulation | Hewlett Packard Enterprise (Forage) | Sep 1, 2026 | [Verify](https://www.theforage.com/) |

> **Verify everything**: [linkedin.com/in/sid-093](https://linkedin.com/in/sid-093) \| [github.com/S-V-J](https://github.com/S-V-J) \| [stjl093@gmail.com](mailto:stjl093@gmail.com)
---

## License

MIT License

© 2026 MyClaude Project