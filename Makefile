# MyClaude Makefile - Full Automated Setup
# Run: make install

.PHONY: install install-system install-python install-claude install-lan verify clean status logs restart stop start

# Default target
all: install

# ============================================================
# FULL AUTOMATED INSTALL (run as: make install)
# ============================================================
install: install-system install-python install-core install-claude install-wrapper setup-bash verify

install-core: setup-user setup-venv setup-nginx setup-systemd

# ============================================================
# SYSTEM PACKAGES (auto-installs nginx, python3, python3-venv)
# ============================================================
install-system:
	@echo "📦 Updating apt and installing system packages..."
	sudo apt update -y
	sudo apt upgrade -y
	sudo apt install -y nginx python3 python3-venv python3-pip curl git

# ============================================================
# PYTHON VENV + LITELLM (as myclaude user)
# ============================================================
install-python:
	@echo "🐍 Setting up Python venv and LiteLLM..."
	sudo -u myclaude python3 -m venv venv 2>/dev/null || true
	sudo -u myclaude venv/bin/pip install --upgrade pip --quiet 2>/dev/null || true
	sudo -u myclaude venv/bin/pip install 'litellm[proxy]' "fastapi<0.140.0" --quiet

# ============================================================
# CORE SETUP (system user, venv, nginx, systemd)
# ============================================================
setup-user:
	@echo "👤 Setting up system user 'myclaude'..."
	@id myclaude &>/dev/null || sudo useradd --system --no-create-home --shell /usr/sbin/nologin myclaude
	@sudo chown -R myclaude:myclaude .

setup-venv: install-python

setup-nginx:
	@echo "🔧 Configuring nginx..."
	@sudo rm -f /etc/nginx/sites-enabled/myclaude
	@sudo cp nginx-myclaude.conf /etc/nginx/sites-enabled/myclaude
	@sudo nginx -t
	@sudo systemctl reload nginx

setup-systemd:
	@echo "⚙️  Installing systemd service..."
	@sed -e "s|__REPO_DIR__|$(CURDIR)|g" \
	    -e "s|__VENV_DIR__|$(CURDIR)/venv|g" \
	    -e "s|__SERVICE_USER__|myclaude|g" \
	    litellm.service.template > /tmp/myclaude.service
	@sudo cp /tmp/myclaude.service /etc/systemd/system/myclaude.service
	@sudo systemctl daemon-reload
	@sudo systemctl enable myclaude
	@sudo systemctl restart myclaude
	@sleep 3
	@systemctl is-active --quiet myclaude && echo "✅ myclaude.service running" || (echo "❌ Failed" && journalctl -u myclaude -n 20 && exit 1)

# ============================================================
# CLAUDE CODE CLI (auto-installs via npm)
# ============================================================
install-claude:
	@echo "🤖 Installing Claude Code CLI..."
	@if ! command -v claude &>/dev/null; then \
		if command -v npm &>/dev/null; then \
			npm install -g @anthropic-ai/claude-code; \
		else \
			echo "❌ npm not found. Install Node.js first: curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs"; \
			exit 1; \
		fi; \
	else \
		echo "✅ Claude Code already installed: $$(claude --version)"; \
	fi

# ============================================================
# WRAPPER SCRIPT (using printf to avoid heredoc issues)
# ============================================================
install-wrapper:
	@echo "📦 Installing 'myclaude' command wrapper..."
	@printf '%s\n' '#!/bin/bash' \
	'SERVICE_NAME="myclaude"' \
	'' \
	'if ! systemctl is-active --quiet "$$SERVICE_NAME" 2>/dev/null; then' \
	'    echo "Starting MyClaude proxy..."' \
	'    sudo systemctl start "$$SERVICE_NAME"' \
	'    sleep 3' \
	'    if ! systemctl is-active --quiet "$$SERVICE_NAME" 2>/dev/null; then' \
	'        echo "Failed to start. Check: journalctl -u $$SERVICE_NAME -n 20"' \
	'        exit 1' \
	'    fi' \
	'fi' \
	'' \
	'export ANTHROPIC_BASE_URL="http://localhost:4000"' \
	'export ANTHROPIC_API_KEY="sk-local-proxy-key"' \
	'' \
	'echo "Launching Claude Code via MyClaude proxy..."' \
	'exec claude "$$@"' > /tmp/myclaude
	@sudo cp /tmp/myclaude /usr/local/bin/myclaude
	@sudo chmod +x /usr/local/bin/myclaude
	@echo "✅ Wrapper installed"

# ============================================================
# BASH ALIASES (using printf)
# ============================================================
setup-bash:
	@echo "📝 Adding bash aliases..."
	@grep -q "# >>> MyClaude >>>" ~/.bashrc || printf '%s\n' '' \
	'# >>> MyClaude >>>' \
	'alias myclaude-start='"'"'sudo systemctl start myclaude'"'"'' \
	'alias myclaude-stop='"'"'sudo systemctl stop myclaude'"'"'' \
	'alias myclaude-status='"'"'sudo systemctl status myclaude'"'"'' \
	'alias myclaude-logs='"'"'journalctl -u myclaude -f'"'"'' \
	'# <<< MyClaude <<<' >> ~/.bashrc
	@echo "✅ Aliases added (run 'source ~/.bashrc')"

# ============================================================
# LAN ACCESS (optional - run: make install-lan)
# ============================================================
install-lan:
	@echo "🌐 Enabling LAN access..."
	@sudo sed -i 's|listen 4000;|listen 0.0.0.0:4000;|g' /etc/nginx/sites-enabled/myclaude
	@if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "Status: active"; then \
		sudo ufw allow 4000/tcp comment "MyClaude proxy"; \
	elif command -v firewall-cmd &>/dev/null && sudo firewall-cmd --state 2>/dev/null | grep -q "running"; then \
		sudo firewall-cmd --permanent --add-port=4000/tcp 2>/dev/null || true; \
		sudo firewall-cmd --reload 2>/dev/null || true; \
	fi
	@sudo systemctl reload nginx
	@IP=$$(hostname -I | awk '{print $$1}'); \
	echo "✅ LAN access enabled at http://$$IP:4000"

# ============================================================
# VERIFICATION
# ============================================================
verify:
	@echo "🔍 Verifying installation..."
	@ss -tlnp 2>/dev/null | grep -q ':4000 ' && echo "✅ Nginx on :4000" || (echo "❌ Nginx not on :4000" && exit 1)
	@ss -tlnp 2>/dev/null | grep -q ':4001 ' && echo "✅ LiteLLM on :4001" || (echo "❌ LiteLLM not on :4001" && exit 1)
	@curl -s --max-time 15 \
		-H "Authorization: Bearer sk-local-proxy-key" \
		-H "Content-Type: application/json" \
		-X POST http://localhost:4000/v1/chat/completions \
		-d '{"model":"claude-sonnet-5","messages":[{"role":"user","content":"Hi"}],"max_tokens":5}' 2>&1 | grep -q "choices\|content" && echo "✅ Proxy chain working" || echo "⚠️  Proxy test returned something unexpected"

# ============================================================
# SERVICE MANAGEMENT
# ============================================================
status:
	@sudo systemctl status myclaude

logs:
	@journalctl -u myclaude -f

restart:
	@sudo systemctl restart myclaude
	@sleep 2
	@make verify

stop:
	@sudo systemctl stop myclaude

start:
	@sudo systemctl start myclaude
	@sleep 2
	@make verify

# ============================================================
# CLEANUP / REINSTALL
# ============================================================
clean:
	@echo "🧹 Cleaning up..."
	@sudo systemctl stop myclaude 2>/dev/null || true
	@sudo systemctl disable myclaude 2>/dev/null || true
	@sudo rm -f /etc/systemd/system/myclaude.service
	@sudo rm -f /etc/nginx/sites-enabled/myclaude
	@sudo systemctl reload nginx 2>/dev/null || true
	@sudo userdel myclaude 2>/dev/null || true
	@rm -rf venv .env
	@sudo rm -f /usr/local/bin/myclaude
	@sed -i '/# >>> MyClaude >>>/,/# <<< MyClaude <<</d' ~/.bashrc 2>/dev/null || true
	@echo "✅ Cleaned. Run 'make install' to reinstall."

reinstall: clean install

# ============================================================
# HELP
# ============================================================
help:
	@echo "MyClaude Makefile - Available targets:"
	@echo ""
	@echo "  make install        - Full automated install (system + python + core + claude + verify)"
	@echo "  make install-system - Install system packages only (apt update/upgrade, nginx, python3)"
	@echo "  make install-claude - Install Claude Code CLI via npm"
	@echo "  make install-lan    - Enable LAN access (optional)"
	@echo "  make verify         - Verify all components are working"
	@echo "  make status         - Show service status"
	@echo "  make logs           - Tail service logs"
	@echo "  make restart        - Restart service and verify"
	@echo "  make stop           - Stop service"
	@echo "  make start          - Start service"
	@echo "  make clean          - Full cleanup"
	@echo "  make reinstall      - Clean + install"
	@echo "  make help           - Show this help"