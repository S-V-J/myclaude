# MyClaude Performance Tuning Guide

## Overview

This guide covers performance optimization for different usage patterns:
- **Light use**: Occasional coding sessions (1-2 hours/day)
- **Regular use**: Daily development (4-8 hours/day)
- **Team use**: Multiple concurrent users
- **CI/CD**: Automated workloads

## Current Baseline (Post-Optimization)

| Metric | Target | Notes |
|--------|--------|-------|
| Idle RAM | <50 MB | nginx master only |
| Startup time | <5 seconds | Cold start |
| First request latency | <10 seconds | Includes startup |
| Active RAM (1 user) | 400-800 MB | Scales with load |
| Max concurrent requests | 8 | Per model (configurable) |

---

## Configuration Tuning

### 1. Idle Timeout (`MYCLAUDE_IDLE_TIMEOUT`)

| Usage Pattern | Recommended | Rationale |
|---------------|-------------|-----------|
| Light (occasional) | 300s (5 min) | Balance responsiveness vs resources |
| Regular (daily) | 600s (10 min) | Reduce restarts during work sessions |
| Team (shared) | 900s (15 min) | Accommodate multiple users |
| CI/CD (automated) | 0 (always-on) | No idle gaps in pipelines |

```bash
# Set in .env
MYCLAUDE_IDLE_TIMEOUT=600
```

### 2. Nginx Worker Processes

```nginx
# /etc/nginx/nginx.conf
# For on-demand (low traffic):
worker_processes 1;

# For team/high traffic:
worker_processes auto;  # Uses all CPU cores

# For CI/CD (always-on):
worker_processes 2;  # Fixed for consistent performance
```

### 3. Nginx Buffer Sizes

```nginx
# Low memory (on-demand):
client_body_buffer_size 64k;
client_header_buffer_size 512;
large_client_header_buffers 2 2k;

# Standard (regular use):
client_body_buffer_size 128k;
client_header_buffer_size 1k;
large_client_header_buffers 4 8k;

# High throughput (team/CI):
client_body_buffer_size 256k;
client_header_buffer_size 2k;
large_client_header_buffers 8 16k;
```

### 4. LiteLLM Concurrency

```yaml
# config.yaml - model_list items
max_parallel_requests: 8  # Default, good for most cases

# For team use (increase):
max_parallel_requests: 16

# For CI/CD (max throughput):
max_parallel_requests: 32
```

### 5. Rate Limiting

```nginx
# nginx-myclaude.conf
# On-demand (gentle):
limit_req_zone $binary_remote_addr zone=myclaude:10m rate=16r/s;
limit_req zone=myclaude burst=32 nodelay;

# Regular (standard):
limit_req_zone $binary_remote_addr zone=myclaude:10m rate=50r/s;
limit_req zone=myclaude burst=100 nodelay;

# Team/CI (aggressive):
limit_req_zone $binary_remote_addr zone=myclaude:10m rate=100r/s;
limit_req zone=myclaude burst=200 nodelay;
```

### 6. Connection Pooling

```yaml
# config.yaml - upstream/keepalive
upstream litellm_backend {
    server 127.0.0.1:4001;
    keepalive 32;           # Increase for high concurrency
    keepalive_requests 1000;
    keepalive_timeout 60s;  # Decrease for on-demand (30s)
}
```

---

## Memory Optimization

### Python GC Tuning (systemd)

```ini
# /etc/systemd/system/myclaude.service
Environment="PYTHONGC=1"           # Enable generational GC
Environment="PYTHONTRACEMALLOC=0"  # Disable memory tracing

# For aggressive memory reduction:
Environment="PYTHONMALLOC=debug"   # Debug allocator (slower, finds leaks)
# Environment="PYTHONMALLOC=default"  # Default allocator
```

### LiteLLM Memory Settings

```yaml
# config.yaml
litellm_settings:
  # Reduce memory footprint
  cache: false                    # Disable response caching
  drop_params: true              # Drop unsupported params
  log_level: "WARNING"           # Reduce log verbosity
  
  # Connection limits
  max_parallel_requests: 8       # Per model
  num_retries: 2                 # Reduce from 3
```

### Systemd Memory Limits

```ini
# /etc/systemd/system/myclaude.service
MemoryMax=2G      # Hard limit
MemoryHigh=1.5G   # Soft limit (throttle)
MemorySwapMax=0   # Disable swap for predictable latency
```

---

## Startup Optimization

### Pre-warming Strategies

```bash
# Option 1: Systemd timer (pre-start at login)
# /etc/systemd/system/myclaude-prewarm.timer
[Timer]
OnBootSec=30
OnUnitActiveSec=300

[Install]
WantedBy=timers.target

# /etc/systemd/system/myclaude-prewarm.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/myclaude --version
```

### Docker Layer Caching

```dockerfile
# Dockerfile - optimize layer order
# 1. System deps (rarely change)
RUN apt-get update && apt-get install -y nginx curl

# 2. Python deps (change occasionally)
COPY requirements.txt .
RUN pip install -r requirements.txt

# 3. Config (change frequently)
COPY config.yaml nginx.conf ./

# 4. Entrypoint (rarely change)
COPY entrypoint.sh .
```

### Health Check Optimization

```yaml
# config.yaml
router_settings:
  health_check_interval: 300  # 5 min (was 30s default)
  
# Reduces startup overhead and periodic checks
```

---

## Load Testing

### Baseline Test
```bash
# Install locust
pip install locust

# Run test
locust -f load_test.py --host=http://localhost:4000 \
  --users=10 --spawn-rate=2 --run-time=60s
```

### Load Test Script
```python
# load_test.py
from locust import HttpUser, task, between

class MyClaudeUser(HttpUser):
    wait_time = between(1, 3)
    
    @task
    def chat_completion(self):
        self.client.post("/v1/chat/completions",
            headers={"Authorization": "Bearer sk-local-proxy-key"},
            json={
                "model": "claude-opus-5",
                "messages": [{"role": "user", "content": "Hello"}],
                "max_tokens": 100
            }
        )
```

### Expected Results

| Concurrent Users | Avg Latency | P99 Latency | Throughput | RAM Usage |
|------------------|-------------|-------------|------------|-----------|
| 1 | 500ms | 1s | 2 req/s | 500 MB |
| 5 | 800ms | 2s | 8 req/s | 800 MB |
| 10 | 1.2s | 3s | 12 req/s | 1.2 GB |
| 20 | 2s | 5s | 15 req/s | 1.8 GB |

---

## Monitoring & Alerting

### Key Metrics to Track

| Metric | Warning | Critical | Action |
|--------|---------|----------|--------|
| RAM usage | >1.5 GB | >3 GB | Restart service, check leaks |
| CPU usage | >80% | >95% | Reduce concurrency, add workers |
| Request latency | >5s | >15s | Check NVIDIA API, increase timeout |
| Error rate | >1% | >5% | Check logs, restart if needed |
| Idle time | N/A | N/A | Verify shutdown working |

### Prometheus Metrics (if enabled)

```yaml
# config.yaml
litellm_settings:
  prometheus_port: 9090  # Enable metrics endpoint
```

Key metrics:
- `litellm_requests_total` - Request counter
- `litellm_request_duration_seconds` - Latency histogram
- `litellm_active_requests` - Current concurrency
- `litellm_model_usage` - Per-model stats

---

## Usage Pattern Configurations

### Light Use (Personal, Occasional)
```bash
# .env
MYCLAUDE_IDLE_TIMEOUT=300

# nginx.conf
worker_processes 1;
client_body_buffer_size 64k;

# config.yaml
max_parallel_requests: 4
cache: false
health_check_interval: 300

# systemd
MemoryMax=1G
```

### Regular Use (Daily Developer)
```bash
# .env
MYCLAUDE_IDLE_TIMEOUT=600

# nginx.conf
worker_processes 1;
client_body_buffer_size 128k;

# config.yaml
max_parallel_requests: 8
cache: false
health_check_interval: 300

# systemd
MemoryMax=2G
```

### Team Use (Shared Server)
```bash
# .env
MYCLAUDE_IDLE_TIMEOUT=900

# nginx.conf
worker_processes auto;
client_body_buffer_size 128k;

# config.yaml
max_parallel_requests: 16
cache: true  # Enable for repeated queries
health_check_interval: 120

# systemd
MemoryMax=4G
```

### CI/CD (Automated)
```bash
# .env
MYCLAUDE_IDLE_TIMEOUT=0  # Always on

# nginx.conf
worker_processes 2;
client_body_buffer_size 256k;

# config.yaml
max_parallel_requests: 32
cache: true
health_check_interval: 60

# systemd
MemoryMax=4G
MemoryHigh=3G
```

---

## Benchmarking Procedure

### 1. Establish Baseline
```bash
# Stop service
sudo systemctl stop myclaude

# Cold start test
time myclaude --version

# Measure
# - Time to "Backend is healthy"
# - Time to first response
# - RAM after startup
```

### 2. Warm Start Test
```bash
# After first run (backend running)
time myclaude --version

# Should be <1 second (no startup)
```

### 3. Idle Shutdown Test
```bash
# Start backend
myclaude --version

# Wait for timeout + 10s
sleep 310

# Check if stopped
ps aux | grep -E 'nginx|litellm'
```

### 4. Load Test
```bash
# Run for 5 minutes
locust -f load_test.py --host=http://localhost:4000 \
  --users=10 --spawn-rate=2 --run-time=300s \
  --headless --csv=results
```

### 5. Memory Profile
```bash
# Install memray
pip install memray

# Profile LiteLLM
memray run -- /home/ML/myclaude/venv/bin/litellm \
  --config /home/ML/myclaude/config.yaml --port 4001

# Analyze
memray summary <output.bin>
memray flamegraph <output.bin>
```

---

## Troubleshooting Performance

### High Latency
1. Check NVIDIA API latency: `curl -w "%{time_total}\n" https://integrate.api.nvidia.com/v1/models`
2. Check local network: `ping localhost`
3. Check LiteLLM queue: `curl http://localhost:4001/metrics | grep queue`

### High Memory
1. Check for leaks: `memray` or `objgraph`
2. Verify GC running: `PYTHONGC=1` in service
3. Check cache size: `cache: false` in config

### Slow Startup
1. Check systemd Type: should be `simple`
2. Check health check: `curl http://localhost:4000/health`
3. Check model loading logs: `journalctl -u myclaude -n 50`