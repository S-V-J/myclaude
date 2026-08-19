# MyClaude On-Demand Usage Guide

## Overview

MyClaude now runs in **on-demand mode** by default. The backend (nginx + LiteLLM) only starts when you run the `myclaude` command and automatically shuts down after a period of inactivity.

## How It Works

```
┌─────────────────────────────────────────────────────────────┐
│                     User Runs `myclaude`                    │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Wrapper checks if backend is running                       │
│  - If NOT running: starts backend (with retries)           │
│  - If running: uses existing backend                        │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Updates "last activity" timestamp                          │
│  Spawns/refreshes idle monitor (background process)        │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Launches Claude Code                                       │
│  (blocks until user exits)                                  │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  On exit: updates activity timestamp                        │
│  Idle monitor continues running                             │
│  After 5 min (default) of no activity: stops backend        │
└─────────────────────────────────────────────────────────────┘
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MYCLAUDE_IDLE_TIMEOUT` | `300` (5 min) | Seconds of inactivity before stopping backend. Set to `0` for always-on mode. |

### Setting Custom Idle Timeout

```bash
# Temporary (single session)
export MYCLAUDE_IDLE_TIMEOUT=600  # 10 minutes
myclaude

# Permanent (add to .env)
echo "MYCLAUDE_IDLE_TIMEOUT=600" >> /home/ML/myclaude/.env

# Disable idle shutdown (always-on)
echo "MYCLAUDE_IDLE_TIMEOUT=0" >> /home/ML/myclaude/.env
```

## Usage Examples

### Basic Usage
```bash
# Start Claude Code (auto-starts backend if needed)
myclaude

# Pass arguments to Claude Code
myclaude --help
myclaude "Write a hello world in Python"
```

### Multiple Concurrent Sessions
```bash
# Terminal 1
myclaude

# Terminal 2 (backend already running, reuses it)
myclaude

# Both sessions share the same backend
# Idle timer resets on each new invocation
```

### Manual Backend Control
```bash
# Check backend status
sudo systemctl status myclaude

# Manually start backend
sudo systemctl start myclaude

# Manually stop backend
sudo systemctl stop myclaude

# View logs
journalctl -u myclaude -f
```

## Expected Behavior

| Scenario | Behavior |
|----------|----------|
| First `myclaude` run | Starts backend (~3-10s), then launches Claude Code |
| Subsequent runs (within 5 min) | Reuses running backend, instant launch |
| No activity for 5 minutes | Backend stops automatically |
| Run `myclaude` after idle | Restarts backend, then launches |
| Set `MYCLAUDE_IDLE_TIMEOUT=0` | Backend runs continuously (always-on) |

## Resource Usage

| State | Expected RAM |
|-------|--------------|
| Idle (backend stopped) | ~5-10 MB (nginx master only) |
| Starting | ~200-400 MB (during startup) |
| Active (1 session) | ~400-800 MB |
| Active (multiple sessions) | Scales with concurrent requests |

## Troubleshooting

### Backend Won't Start
```bash
# Check service status
sudo systemctl status myclaude

# View recent logs
journalctl -u myclaude -n 50

# Common issues:
# - Missing NVIDIA API keys in .env
# - Port 4000/4001 already in use
# - Config file syntax error
```

### Idle Shutdown Not Working
```bash
# Check if monitor is running
ls -la /tmp/myclaude/

# Check activity timestamp
cat /tmp/myclaude/last_activity

# Check current time vs activity
date +%s
```

### Wrapper Errors
```bash
# Test wrapper syntax
bash -n /usr/local/bin/myclaude

# Run with debug
bash -x /usr/local/bin/myclaude --version
```

## Advanced: Always-On Mode

If you prefer the old always-on behavior:

```bash
# Option 1: Set timeout to 0
echo "MYCLAUDE_IDLE_TIMEOUT=0" >> /home/ML/myclaude/.env
sudo systemctl restart myclaude

# Option 2: Use systemd directly
sudo systemctl enable --now myclaude
# Then use: ANTHROPIC_BASE_URL=http://localhost:4001 claude
```

## Docker Usage

```bash
# Build and start
cd /home/ML/myclaude/docker
docker-compose up -d

# View logs
docker-compose logs -f

# Stop
docker-compose down
```

The Docker entrypoint includes the same on-demand idle monitoring logic.

## Key Files

| File | Purpose |
|------|---------|
| `/usr/local/bin/myclaude` | Main wrapper script |
| `/home/ML/myclaude/.env` | Configuration (idle timeout, API keys) |
| `/etc/systemd/system/myclaude.service` | Systemd service (Restart=on-failure) |
| `/tmp/myclaude/last_activity` | Timestamp of last activity |
| `/tmp/myclaude/monitor.pid` | Idle monitor process ID |
| `/tmp/myclaude.lock` | Lock file for race condition prevention |