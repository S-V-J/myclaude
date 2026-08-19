# MyClaude Troubleshooting Guide

## Quick Diagnostics

### Check Service Status
```bash
# Systemd service
sudo systemctl status myclaude

# Docker container
docker ps -a | grep myclaude
docker-compose ps

# Process status
ps aux | grep -E 'nginx|litellm'
```

### Check Logs
```bash
# Systemd logs
journalctl -u myclaude -n 50
journalctl -u myclaude -f  # follow

# Docker logs
docker-compose logs -f myclaude

# nginx logs
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log

# LiteLLM logs (if file logging enabled)
tail -f /home/ML/myclaude/litellm.log
```

### Test Connectivity
```bash
# Test nginx health endpoint
curl -v http://localhost:4000/health

# Test LiteLLM directly
curl -v http://localhost:4001/health

# Test full proxy stack
curl -X POST http://localhost:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-local-proxy-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-5","messages":[{"role":"user","content":"test"}],"max_tokens":5}'
```

---

## Common Issues

### 1. Backend Won't Start

#### Symptoms
- `myclaude` hangs on "Starting MyClaude backend..."
- Timeout error after 30 seconds

#### Causes & Solutions

**Missing API Keys**
```bash
# Check .env file
cat /home/ML/myclaude/.env | grep NVIDIA_API_KEY

# Must have at least PROJECT_1
NVIDIA_API_KEY_PROJECT_1="nvapi-..."
```

**Port Already in Use**
```bash
# Check what's using ports 4000, 4001
sudo ss -tlnp | grep -E ':4000|:4001'

# Kill conflicting processes or change ports in config
```

**Config Syntax Error**
```bash
# Validate nginx config
sudo nginx -t

# Validate LiteLLM config
/home/ML/myclaude/venv/bin/litellm --config /home/ML/myclaude/config.yaml --port 4001 --host 0.0.0.0 --dry-run
```

**Permission Issues**
```bash
# Check file ownership
ls -la /home/ML/myclaude/
# Should be owned by myclaude user or your user

# Fix if needed
sudo chown -R myclaude:myclaude /home/ML/myclaude
```

---

### 2. Idle Shutdown Not Working

#### Symptoms
- Backend continues running after 5+ minutes of inactivity
- RAM usage stays high

#### Causes & Solutions

**Restart Policy Still Set to "always"**
```bash
# Check current service
grep Restart /etc/systemd/system/myclaude.service
# Must be: Restart=on-failure

# Fix: Update service file and reload
sudo systemctl daemon-reload
sudo systemctl restart myclaude
```

**Monitor Process Died**
```bash
# Check monitor status
ls -la /tmp/myclaude/
cat /tmp/myclaude/monitor.pid

# If PID exists but process dead, wrapper will respawn on next run
```

**Activity File Not Updating**
```bash
# Check timestamp
cat /tmp/myclaude/last_activity
date +%s  # Compare with current time

# Should update on every myclaude invocation
```

**MYCLAUDE_IDLE_TIMEOUT Set to 0**
```bash
# Check .env
grep MYCLAUDE_IDLE_TIMEOUT /home/ML/myclaude/.env
# If 0, idle shutdown is disabled
```

---

### 3. High Memory Usage

#### Symptoms
- System using >1GB RAM when idle
- OOM kills or slow performance

#### Causes & Solutions

**Nginx Worker Processes Set to "auto"**
```bash
# Check nginx config
grep worker_processes /etc/nginx/nginx.conf
# Should be: worker_processes 1; for on-demand

# Fix: Update and reload
sudo nginx -t && sudo systemctl reload nginx
```

**LiteLLM Caching Enabled**
```bash
# Check config.yaml
grep -A 5 "litellm_settings:" /home/ML/myclaude/config.yaml
# Should have: cache: false

# Fix: Update config and restart
sudo systemctl restart myclaude
```

**Too Many Nginx Workers**
```bash
# Check current workers
ps aux | grep 'nginx: worker' | wc -l
# Should be 1 worker + 1 master for on-demand
```

**No Memory Limits**
```bash
# Check systemd limits
grep MemoryMax /etc/systemd/system/myclaude.service
# Should have: MemoryMax=4G, MemoryHigh=3.5G

# For Docker, check docker-compose.yml deploy.resources.limits.memory
```

---

### 4. Slow Startup

#### Symptoms
- First request takes >10 seconds
- Timeout errors during startup

#### Causes & Solutions

**Systemd Type=notify Timeout**
```bash
# Check service type
grep ^Type /etc/systemd/system/myclaude.service
# Should be: Type=simple (not notify)

# notify requires sd_notify() which LiteLLM may not support
```

**Health Check Failing**
```bash
# Test health endpoint manually
curl -v http://localhost:4000/health

# Check nginx upstream
curl -v http://localhost:4001/health

# Increase timeout in wrapper if needed
# wait_for_healthy() max_wait=30
```

**LiteLLM Slow Model Loading**
```bash
# Check logs for model loading time
journalctl -u myclaude -n 100 | grep -i "load\|model\|init"

# Consider reducing models in config.yaml if not all needed
```

---

### 5. Wrapper Errors

#### "Another myclaude instance is starting backend, waiting..."
```bash
# This is normal - flock is preventing race condition
# Wait a few seconds, it will proceed

# If stuck, check for stale lock
ls -la /tmp/myclaude.lock
rm -f /tmp/myclaude.lock  # Only if no myclaude processes running
```

#### "Failed to start backend after 3 attempts"
```bash
# Check journal for details
journalctl -u myclaude -n 30

# Common causes:
# - API key invalid/expired
# - Network connectivity to NVIDIA
# - Config file error
```

#### Permission Denied on systemctl
```bash
# User needs sudo rights for systemctl
# Check /etc/sudoers for NOPASSWD rules

# Or run: sudo systemctl start myclaude manually first
```

---

### 6. Docker Issues

#### Container Exits Immediately
```bash
# Check logs
docker-compose logs myclaude

# Common: missing .env file or invalid API keys
```

#### Health Check Failing
```bash
# Run health check manually
docker exec myclaude /healthcheck.sh

# Check nginx inside container
docker exec myclaude curl -f http://localhost:4000/health
```

#### Port Conflicts
```bash
# Check host ports
ss -tlnp | grep -E ':4000|:4001'

# Change ports in docker-compose.yml if needed
ports:
  - "4000:4000"
  - "4001:4001"
```

---

### 7. TLS/SSL Issues

#### Certificate Errors
```bash
# Check certificate exists
ls -la /etc/ssl/myclaude/

# Regenerate with setup-tls.sh
sudo /home/ML/myclaude/setup-tls.sh generate localhost true
```

#### Browser/Client Certificate Warnings
```bash
# Self-signed certs will show warnings
# For local development, this is expected
# Add to trusted certs or use HTTP (port 4000)
```

---

## Debug Mode

### Enable Debug Logging
```bash
# LiteLLM debug
echo "LITELLM_LOG_LEVEL=DEBUG" >> /home/ML/myclaude/.env
sudo systemctl restart myclaude

# Wrapper debug
bash -x /usr/local/bin/myclaude --version
```

### Trace Systemd
```bash
# Increase log level
sudo systemctl log-level=debug
journalctl -u myclaude -f
```

---

## Reset Procedures

### Full Service Reset
```bash
# Stop everything
sudo systemctl stop myclaude
sudo systemctl stop nginx

# Clear state
rm -rf /tmp/myclaude/
sudo rm -f /home/ML/myclaude/litellm.db

# Restart
sudo systemctl start nginx
sudo systemctl start myclaude
```

### Docker Reset
```bash
docker-compose down -v
docker-compose build --no-cache
docker-compose up -d
```

### Complete Reinstall
```bash
# Backup config
cp /home/ML/myclaude/.env /tmp/myclaude.env.backup
cp /home/ML/myclaude/config.yaml /tmp/myclaude.config.backup

# Reinstall
cd /home/ML/myclaude
sudo ./install.sh --auto

# Restore config
cp /tmp/myclaude.env.backup /home/ML/myclaude/.env
cp /tmp/myclaude.config.backup /home/ML/myclaude/config.yaml
sudo systemctl restart myclaude
```

---

## Getting Help

### Information to Collect
When reporting issues, include:
```bash
# System info
uname -a
cat /etc/os-release

# Service status
sudo systemctl status myclaude
journalctl -u myclaude -n 50

# Process info
ps aux | grep -E 'nginx|litellm'

# Memory usage
free -h
ps aux | awk '/[l]itellm|[n]ginx: worker/ {sum+=$6} END {print "Total: " sum/1024 " MB"}'

# Config
cat /home/ML/myclaude/.env
cat /home/ML/myclaude/config.yaml
```

### Useful Commands Reference
```bash
# Service management
sudo systemctl {start|stop|restart|status} myclaude
sudo systemctl {enable|disable} myclaude

# Logs
journalctl -u myclaude -f
journalctl -u myclaude -n 100

# Config validation
sudo nginx -t
/home/ML/myclaude/venv/bin/litellm --config /home/ML/myclaude/config.yaml --port 4001 --dry-run

# Network
ss -tlnp | grep -E ':4000|:4001'
curl -v http://localhost:4000/health

# Memory
ps aux | grep -E 'nginx|litellm' | awk '{sum+=$6} END {print sum/1024 " MB"}'
```