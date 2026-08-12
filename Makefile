# MyClaude Makefile
# Usage: make install | make status | make logs | make restart | make clean

.PHONY: all install status logs restart stop start clean reinstall help

# Default: run full install
all: install

# Full automated install — delegates to install.sh
install:
	@echo "Running MyClaude installer..."
	@bash install.sh

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
	@echo "  make install   - Run full installer (same as: bash install.sh)"
	@echo "  make status    - Show myclaude service status"
	@echo "  make logs      - Tail myclaude service logs"
	@echo "  make restart   - Restart myclaude service"
	@echo "  make stop      - Stop myclaude service"
	@echo "  make start     - Start myclaude service"
	@echo "  make clean     - Remove everything (service, user, venv, config)"
	@echo "  make reinstall - Clean then install"
	@echo "  make help      - Show this help"
