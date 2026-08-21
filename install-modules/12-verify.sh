#!/bin/bash
# Module 12: Verify installation
set -euo pipefail

source "$MODULES_DIR/01-detect-os.sh"

log_info "Verifying installation..."

ERRORS=0

# Check required commands
for cmd in nginx python3 litellm npm node; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Missing command: $cmd"
        ((ERRORS++))
    fi
done

# Check config files
for file in "$REPO_DIR/config.yaml" "$REPO_DIR/.env" "$REPO_DIR/myclaude-wrapper.sh" /etc/nginx/sites-enabled/myclaude; do
    if [[ ! -f "$file" ]]; then
        log_error "Missing file: $file"
        ((ERRORS++))
    fi
done

# Check systemd service
if [[ ! -f /etc/systemd/system/myclaude.service ]]; then
    log_error "Missing systemd service"
    ((ERRORS++))
fi

# Check nginx config syntax (syntax check only - ignore pid permission error)
if ! nginx -t -c /etc/nginx/nginx.conf 2>&1 | grep -q "syntax is ok"; then
    log_error "nginx configuration test failed"
    ((ERRORS++))
fi

# Check venv
if [[ ! -d "$REPO_DIR/venv" ]]; then
    log_error "Virtual environment not found"
    ((ERRORS++))
fi

# Check ports
if ! ss -tlnp | grep -q ':4000'; then
    log_warning "Port 4000 (nginx) not listening - service may not be started"
fi

if [[ $ERRORS -eq 0 ]]; then
    log_success "All verification checks passed"
    return 0
else
    log_error "Verification failed with $ERRORS errors"
    return 1
fi