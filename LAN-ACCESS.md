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

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Connection refused | Check `sudo systemctl status myclaude` and `sudo systemctl status nginx` |
| 403 Forbidden | Wrong API key — use `sk-local-proxy-key` |
| Timeout | Check firewall: `sudo ufw status` or `sudo firewall-cmd --list-ports` |
| Can't reach from phone | Ensure both devices are on the same WiFi/router |
| Nginx won't reload | Check config: `sudo nginx -t` |