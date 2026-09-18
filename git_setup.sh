#!/bin/bash
# Git setup script for myclaude repository

set -e

echo "Setting up git repository..."

# Initialize git if needed
if [ ! -d .git ]; then
    git init
    git branch -M master
fi

# Add all files except protected ones and .env
echo "Adding files to git..."
git add .gitignore README.md LICENSE install.sh uninstall.sh setup-tls.sh litellm.service.template utils/

# Show what's being committed
echo "Files to be committed:"
git status --short

# Commit
echo "Creating commit..."
git commit -m "feat: modular installation system for MyClaude proxy

- Add install.sh with dynamic port discovery
- Add uninstall.sh with backup support
- Add setup-tls.sh for HTTPS with Let's Encrypt
- Add litellm.service.template for systemd
- Add utils/backup.sh for config backups
- Add utils/status.sh for service monitoring
- Add comprehensive README.md documentation
- Add MIT LICENSE

All installation scripts use dynamic port discovery
to avoid conflicts with other applications.

Protected files (build_config.sh, config_base.yaml, models/,
myclaude.sh, nginx-myclaude.conf, .env) remain unchanged."

echo "Git setup complete!"