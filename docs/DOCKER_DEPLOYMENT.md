# MyClaude Docker Deployment Guide

## Overview

MyClaude provides a complete Docker-based deployment for running the NVIDIA NIM proxy with on-demand activation. The Docker setup includes:

- **Multi-stage build** for minimal image size (~400-500MB)
- **On-demand idle monitoring** built into the entrypoint
- **Production and development profiles**
- **Health checks** for container orchestration
- **Resource limits** and security hardening

## Quick Start

### Prerequisites
- Docker Engine 20.10+
- Docker Compose 2.0+
- NVIDIA API key(s) from https://build.nvidia.com

### 1. Configure Environment
```bash
cd /home/ML/myclaude/docker

# Copy example environment
cp ../.env.example .env

# Edit with your API keys
nano .env
# Required: NVIDIA_API_KEY_PROJECT_1="nvapi-..."
```

### 2. Build and Run
```bash
# Production deployment
docker-compose up -d

# Development deployment (with live reload)
docker-compose --profile dev up -d
```

### 3. Verify
```bash
# Check health
curl http://localhost:4000/health

# View logs
docker-compose logs -f myclaude
```

## Configuration

### Environment Variables (.env)

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `NVIDIA_API_KEY_PROJECT_1` | Yes | - | Primary NVIDIA NIM API key |
| `NVIDIA_API_KEY_PROJECT_2` | No | Falls back to PROJECT_1 | Sonnet model key |
| `NVIDIA_API_KEY_PROJECT_3` | No | Falls back to PROJECT_1 | Sonnet 1M model key |
| `NVIDIA_API_KEY_PROJECT_4` | No | Falls back to PROJECT_1 | Haiku model key |
| `LITELLM_MASTER_KEY` | No | Auto-generated | Local proxy auth key |
| `MYCLAUDE_IDLE_TIMEOUT` | No | `300` | Idle timeout in seconds (0 = always-on) |

### Resource Limits (docker-compose.yml)

```yaml
deploy:
  resources:
    limits:
      memory: 2g      # Max memory
      cpus: '2.0'     # Max CPU cores
    reservations:
      memory: 512m    # Guaranteed memory
      cpus: '0.5'     # Guaranteed CPU
```

Adjust based on your system capacity and expected load.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Docker Container                         │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                  Entrypoint                         │   │
│  │  - Starts nginx + LiteLLM                           │   │
│  │  - Spawns idle monitor (30s interval)              │   │
│  │  - Stops services after MYCLAUDE_IDLE_TIMEOUT      │   │
│  │  - Restarts on next request                         │   │
│  └─────────────────────────────────────────────────────┘   │
│           │                           │                     │
│           ▼                           ▼                     │
│  ┌───────────────┐           ┌───────────────┐             │
│  │    nginx      │           │   LiteLLM     │             │
│  │   (port 4000) │──────────▶│  (port 4001)  │             │
│  │  - Rate limit │           │  - 4 models   │             │
│  │  - Health chk │           │  - 80 RPM     │             │
│  └───────────────┘           └───────────────┘             │
└─────────────────────────────────────────────────────────────┘
```

## Profiles

### Production (default)
```bash
docker-compose up -d
```
- Optimized for production use
- Resource limits enforced
- Read-only root filesystem (with tmpfs exceptions)
- Health checks enabled
- Structured JSON logging

### Development
```bash
docker-compose --profile dev up -d myclaude-dev
```
- Mounts source code for live editing
- Shorter idle timeout (60s)
- Debug logging enabled
- Runs `tail -f /dev/null` for manual testing

## On-Demand Behavior in Docker

The Docker entrypoint implements the same on-demand logic as the host wrapper:

1. **Container starts** → nginx + LiteLLM start automatically
2. **Idle monitor runs** → checks every 30 seconds
3. **After timeout** → services stop gracefully
4. **Next request** → entrypoint restarts services

### Health Checks

```yaml
healthcheck:
  test: ["/healthcheck.sh"]
  interval: 30s
  timeout: 5s
  retries: 3
  start_period: 15s
```

The health check verifies the nginx `/health` endpoint (full proxy stack).

## Security

### Non-Root User
- Runs as `myclaude` user (UID 1000)
- No root privileges in container

### Capabilities
- Only `CAP_NET_BIND_SERVICE` for binding to ports <1024 (if needed)
- All other capabilities dropped

### Filesystem
- Read-only root filesystem
- tmpfs for `/tmp/myclaude`, `/var/cache/nginx`, `/var/run`

### Network
- Only exposes ports 4000 and 4001
- No host network mode

## TLS/SSL Configuration

For HTTPS support, mount certificates:

```yaml
volumes:
  - ./certs:/etc/nginx/certs:ro
```

Then uncomment the HTTPS server block in `nginx-myclaude.conf` and update certificate paths.

## Monitoring

### Container Health
```bash
# Check container health status
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Health}}"

# View health check logs
docker inspect myclaude | jq '.[0].State.Health'
```

### Resource Usage
```bash
# Real-time stats
docker stats myclaude

# Detailed inspect
docker inspect myclaude | jq '.[0].HostConfig.Resources'
```

### Application Logs
```bash
# Follow logs
docker-compose logs -f myclaude

# Last 100 lines
docker-compose logs --tail 100 myclaude
```

## Troubleshooting

### Container Won't Start
```bash
# Check logs
docker-compose logs myclaude

# Common issues:
# - Missing API keys in .env
# - Port conflicts (4000, 4001 already in use)
# - Config file syntax error
```

### Health Check Failing
```bash
# Manual health check
docker exec myclaude /healthcheck.sh

# Check nginx
docker exec myclaude curl -f http://localhost:4000/health

# Check LiteLLM directly
docker exec myclaude curl -f http://localhost:4001/health
```

### Memory Issues
```bash
# Check memory usage
docker exec myclaude ps aux | grep -E 'nginx|litellm'

# Increase memory limit in docker-compose.yml
# deploy:
#   resources:
#     limits:
#       memory: 4g
```

## Building Custom Images

### Build Arguments
```bash
# Build with custom base image
docker-compose build --build-arg BASE_IMAGE=python:3.12-slim

# Build without cache
docker-compose build --no-cache
```

### Multi-Architecture
```bash
# Build for multiple platforms
docker buildx build --platform linux/amd64,linux/arm64 -t myclaude:latest .
```

## Production Checklist

- [ ] Set strong `LITELLM_MASTER_KEY` in .env
- [ ] Configure resource limits for your workload
- [ ] Set up log aggregation (ELK, Loki, etc.)
- [ ] Configure monitoring alerts (health checks, memory, CPU)
- [ ] Set up backup for persistent volumes
- [ ] Test idle shutdown/restart behavior
- [ ] Configure firewall for ports 4000/4001
- [ ] Set up TLS certificates for production HTTPS
- [ ] Document recovery procedures

## File Reference

| File | Description |
|------|-------------|
| `docker/Dockerfile` | Multi-stage build |
| `docker/docker-compose.yml` | Service orchestration |
| `docker/entrypoint.sh` | Service manager + idle monitor |
| `docker/healthcheck.sh` | Health check script |
| `docker/.dockerignore` | Build exclusions |
| `../config.yaml` | LiteLLM configuration |
| `../nginx-myclaude.conf` | nginx configuration |
| `../.env` | Environment variables |