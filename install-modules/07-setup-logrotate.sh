#!/bin/bash
# Module 07: Setup logrotate for myclaude logs
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Setting up logrotate..."

sudo tee /etc/logrotate.d/myclaude > /dev/null <<'LOGEOF'
/var/log/nginx/myclaude*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 www-data adm
    sharedscripts
    postrotate
        [ -f /var/run/nginx.pid ] && kill -USR1 $(cat /var/run/nginx.pid)
    endscript
}

$REPO_DIR/logs/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 $INSTALL_USER $INSTALL_USER
}
LOGEOF

# Create log directory
mkdir -p "$REPO_DIR/logs"

log_info "logrotate configured"