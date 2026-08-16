# MyClaude Makefile
# Usage: make install | make status | make logs | make restart | make clean

.PHONY: all install install-auto status logs restart stop start clean reinstall help test

# Default: run full interactive install
all: install

# Full interactive install — delegates to install.sh
install:
	@bash install.sh

# Full automated install — delegates to install.sh --auto
# Requires NVIDIA_API_KEY environment variable
install-auto:
	@if [ -z "$$NVIDIA_API_KEY" ]; then echo "ERROR: NVIDIA_API_KEY required. Usage: make install-auto NVIDIA_API_KEY=..."; exit 1; fi
	@bash install.sh --auto

# Service management
status:
	@sudo systemctl status myclaude

logs:
	@journalctl -u myclaude -f

restart:
	@sudo systemctl restart myclaude
	@sleep 2
	@make status

stop:
	@sudo systemctl stop myclaude

start:
	@sudo systemctl start myclaude
	@sleep 2
	@make status

# Test all models
test:
	@echo "Testing all 4 models..."
	@for model in claude-opus-5 claude-sonnet-5 claude-sonnet-5-1m claude-haiku-4-5; do \
		echo -n "$$model: "; \
		curl -s --max-time 30 \
			-H "Authorization: Bearer sk-local-proxy-key" \
			-H "Content-Type: application/json" \
			-X POST http://localhost:4000/v1/chat/completions \
			-d "{\"model\":\"$$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello\"}],\"max_tokens\":50}" 2>&1 | \
		python3 -c "import sys, json; d=json.load(sys.stdin); c=d.get('content') or d.get('choices', [{}])[0].get('message', {}).get('content'); print(c[0]['text'][:50] if c and isinstance(c, list) and len(c)>0 else 'empty')" 2>/dev/null; \
	done

# Full cleanup (removes service, nginx config, user, venv, wrapper)
clean:
	@echo "Cleaning up MyClaude..."
	@sudo systemctl stop myclaude 2>/dev/null || true
	@sudo systemctl disable myclaude 2>/dev/null || true
	@sudo rm -f /etc/systemd/system/myclaude.service
	@sudo rm -f /etc/nginx/sites-enabled/myclaude
	@sudo systemctl reload nginx 2>/dev/null || true
	@sudo userdel myclaude 2>/dev/null || true
	@rm -rf venv .env
	@sudo rm -f /usr/local/bin/myclaude
	@sed -i '/# >>> MyClaude >>>/,/# <<< MyClaude <<</d' ~/.bashrc 2>/dev/null || true
	@echo "Cleaned. Run 'make install' to reinstall."

# Clean + reinstall
reinstall: clean install

# Show help
help:
	@echo "MyClaude Makefile targets:"
	@echo ""
	@echo "  make install       - Run full interactive installer (bash install.sh)"
	@echo "  make install-auto  - Run automated installer (needs NVIDIA_API_KEY env)"
	@echo "  make status        - Show myclaude service status"
	@echo "  make logs          - Tail myclaude service logs"
	@echo "  make restart       - Restart myclaude service"
	@echo "  make stop          - Stop myclaude service"
	@echo "  make start         - Start myclaude service"
	@echo "  make test          - Test all 4 models"
	@echo "  make clean         - Remove everything (service, user, venv, config)"
	@echo "  make reinstall     - Clean then install"
	@echo "  make help          - Show this help"