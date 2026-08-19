#!/bin/bash
# MyClaude Docker Deployment Script
# Usage: bash docker/deploy.sh [build|up|down|logs|restart|status]

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="$REPO_DIR/docker/docker-compose.yml"
ENV_FILE="$REPO_DIR/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[DOCKER]${NC} $*"; }
log_success() { echo -e "${GREEN}[DOCKER]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[DOCKER]${NC} $*"; }
log_error() { echo -e "${RED}[DOCKER]${NC} $*"; }

# Check for .env
if [ ! -f "$ENV_FILE" ]; then
    log_error ".env file not found at $ENV_FILE"
    log_info "Run: NVIDIA_API_KEY_PROJECT_1=xxx bash install-modular.sh --auto"
    exit 1
fi

# Load env for docker-compose
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

cmd="${1:-up}"

case "$cmd" in
    build)
        log_info "Building Docker image..."
        docker compose -f "$COMPOSE_FILE" build
        log_success "Build complete"
        ;;
    up)
        log_info "Starting MyClaude Docker (on-demand mode)..."
        docker compose -f "$COMPOSE_FILE" up -d
        log_success "Started. Access at http://localhost:4000"
        log_info "Run 'bash docker/deploy.sh logs' to see logs"
        ;;
    down)
        log_info "Stopping MyClaude Docker..."
        docker compose -f "$COMPOSE_FILE" down
        log_success "Stopped"
        ;;
    restart)
        log_info "Restarting MyClaude Docker..."
        docker compose -f "$COMPOSE_FILE" restart
        log_success "Restarted"
        ;;
    logs)
        docker compose -f "$COMPOSE_FILE" logs -f
        ;;
    status)
        docker compose -f "$COMPOSE_FILE" ps
        ;;
    shell)
        log_info "Opening shell in running container..."
        docker compose -f "$COMPOSE_FILE" exec myclaude /bin/bash
        ;;
    *)
        echo "Usage: $0 [build|up|down|restart|logs|status|shell]"
        exit 1
        ;;
esac