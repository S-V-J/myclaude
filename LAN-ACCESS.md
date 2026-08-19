# Accessing MyClaude from Your Local Network

This guide explains how to use MyClaude from other devices (phones, tablets, other PCs) on the same WiFi/LAN.

## What You Need

1. MyClaude installed on a **Linux machine** (the server/host)
2. Both devices on the **same local network** (same WiFi/router)
3. Local network access enabled during install (or re-run the nginx config step)

---

## Step 1 — Enable Local Network Access (Server)

During installation, answer **Yes** when asked:

```
🌐 Local Network Hosting
Would you like to allow other devices on your local network to use MyClaude? (y/n): y
```

This configures nginx to listen on all interfaces and opens port 4000 in your firewall.

If you already installed without this option, re-run the installer or manually:

```bash
# Edit nginx config
sudo nano /etc/nginx/sites-enabled/myclaude
# Change: listen 4000;
# To:     listen 0.0.0.0:4000;

# Open firewall
sudo ufw allow 4000/tcp   # Ubuntu/Debian
# OR
sudo firewall-cmd --permanent --add-port=4000/tcp && sudo firewall-cmd --reload

# Reload nginx
sudo systemctl reload nginx
```

---

## Step 2 — Find Your Server's Local IP (Server)

```bash
hostname -I
```

Example output: `192.168.1.42`

---

## Step 3 — Connect from Another Device

### From another Linux/macOS machine:

```bash
export ANTHROPIC_BASE_URL="http://192.168.1.42:4000"
export ANTHROPIC_API_KEY="sk-local-proxy-key"
claude
```

### From a phone/tablet (using a terminal app like Termux):

```bash
export ANTHROPIC_BASE_URL="http://192.168.1.42:4000"
export ANTHROPIC_API_KEY="sk-local-proxy-key"
claude
```

### Via API directly (any device):

```
POST http://192.168.1.42:4000/v1/chat/completions
Headers:
  Authorization: Bearer sk-local-proxy-key
  Content-Type: application/json
```

---

## Step 4 — Test the Connection

From the remote device:

```bash
curl http://192.168.1.42:4000/health
# Expected: "healthy"

curl http://192.168.1.42:4000/
# Expected: JSON with status info
```

---

## HTTPS / TLS Setup (for LAN with encryption)

If you enabled TLS during installation (or ran `sudo bash setup-tls.sh generate myserver.local true`):

### Server (already done if TLS enabled):
```bash
# Certs generated with SAN for all LAN IPs
# nginx already configured for HTTPS on port 4443
sudo ufw allow 4443/tcp
sudo systemctl reload nginx
```

### Client (any device) - use `-k` for self-signed cert:
```bash
export ANTHROPIC_BASE_URL="https://192.168.1.42:4443"
export ANTHROPIC_API_KEY="sk-local-proxy-key"
claude
```

### Or trust cert system-wide:
```bash
# On the client device:
sudo cp /etc/ssl/myclaude/myclaude.crt /usr/local/share/ca-certificates/myclaude.crt
sudo update-ca-certificates
# Then connect without -k:
export ANTHROPIC_BASE_URL="https://192.168.1.42:4443"
export ANTHROPIC_API_KEY="sk-local-proxy-key"
claude
```

---

## Security Notes

- **Local network only** — MyClaude is NOT exposed to the internet by default
- The `sk-local-proxy-key` acts as a shared secret — don't share it publicly
- If you need internet access, put MyClaude behind a VPN (e.g., Tailscale, ZeroTier)
- To disable LAN access later:
  ```bash
  sudo sed -i 's/listen 0.0.0.0:4000;/listen 4000;/' /etc/nginx/sites-enabled/myclaude
  sudo systemctl reload nginx
  ```

---

## Model Configuration Note

**All 4 Claude Code models use Nemotron 3 Ultra with different API keys for load isolation:**

| Model in Claude Code | NVIDIA Backend | API Key |
|---------------------|----------------|---------|
| Default / Opus (1M) | Nemotron 3 Ultra | PROJECT_1 |
| Sonnet | Nemotron 3 Ultra | PROJECT_2 |
| Sonnet 5 (1M) | Nemotron 3 Ultra | PROJECT_3 |
| Haiku | Nemotron 3 Ultra | PROJECT_4 |

This provides **80 RPM combined** (20 RPM per key) with load isolation.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Connection refused | Check `sudo systemctl status myclaude` and `sudo systemctl status nginx` |
| 403 Forbidden | Wrong API key — use `sk-local-proxy-key` |
| Timeout | Check firewall: `sudo ufw status` or `sudo firewall-cmd --list-ports` |
| Can't reach from phone | Ensure both devices are on the same WiFi/router |
| Nginx won't reload | Check config: `sudo nginx -t` |
| TLS cert errors | Use `curl -k` or trust cert system-wide (see above) |