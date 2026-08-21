#!/bin/bash
# Module 06: Setup systemd service (runs as current user, not new user)
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Setting up systemd service..."

VENV_DIR="$REPO_DIR/venv"

# Create systemd service running as current user with sudo
sudo tee /etc/systemd/system/myclaude.service > /dev/null <<SVC_EOF
[Unit]
Description=LiteLLM Proxy for MyClaude (NVIDIA NIM)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=$INSTALL_USER
Group=$INSTALL_USER
WorkingDirectory=$REPO_DIR
EnvironmentFile=$REPO_DIR/.env
Environment="PORT=4001"
Environment="PYTHONUNBUFFERED=1"
Environment="PYTHONDONTWRITEBYTECODE=1"
Environment="LITELLM_LOG_LEVEL=INFO"
Environment="LITELLM_LOG_FORMAT=json"

# Basic security (no strict restrictions since running as user)
NoNewPrivileges=yes
PrivateTmp=yes

LimitNOFILE=65536
LimitNPROC=4096
MemoryMax=4G
MemoryHigh=3.5G

Restart=on-failure
RestartSec=5

ExecStartPre=/bin/bash -c 'test -f $REPO_DIR/config.yaml || exit 1'
ExecStartPre=/bin/bash -c 'test -r $REPO_DIR/.env || exit 1'
ExecStart=$VENV_DIR/bin/litellm --config $REPO_DIR/config.yaml --port 4001 --host 0.0.0.0

StandardOutput=journal
StandardError=journal
SyslogIdentifier=myclaude-litellm

ExecReload=/bin/kill -HUP \$MAINPID
KillSignal=SIGTERM
KillMode=mixed
TimeoutStopSec=30
TimeoutStartSec=60

[Install]
WantedBy=default.target
SVC_EOF

sudo systemctl daemon-reload
sudo systemctl enable myclaude
sudo systemctl restart myclaude

log_info "Systemd service created and started"
