# Always-On vs On-Demand: Tradeoffs Analysis

## Executive Summary

| Aspect | Always-On | On-Demand (Default) |
|--------|-----------|---------------------|
| **Idle RAM** | ~927 MB | ~5-10 MB |
| **Active RAM** | ~927 MB + load | ~400-800 MB + load |
| **First Request** | Instant | 3-10 seconds |
| **Subsequent Requests** | Instant | Instant |
| **CPU Idle** | ~1-2% | ~0% |
| **Power Consumption** | Higher | Minimal |
| **Best For** | Teams, CI/CD, high-frequency | Individuals, intermittent use |

---

## Detailed Comparison

### Resource Consumption

#### Always-On Mode
```
┌────────────────────────────────────────────────────────────┐
│  Continuous Resource Usage                                 │
├────────────────────────────────────────────────────────────┤
│  nginx master:     ~5 MB                                   │
│  nginx workers:    ~80 MB (16 workers × 5 MB)             │
│  LiteLLM:          ~800-900 MB (models + connections)     │
│  ──────────────────────────────────────────────────────   │
│  TOTAL IDLE:       ~900 MB                                 │
│  TOTAL ACTIVE:     ~900 MB + request overhead             │
└────────────────────────────────────────────────────────────┘
```

#### On-Demand Mode
```
┌────────────────────────────────────────────────────────────┐
│  Idle State (backend stopped)                              │
├────────────────────────────────────────────────────────────┤
│  nginx master:     ~5 MB (if nginx stays running)         │
│  ──────────────────────────────────────────────────────   │
│  TOTAL IDLE:       ~5-10 MB                                │
└────────────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────────────┐
│  Active State (after startup)                              │
├────────────────────────────────────────────────────────────┤
│  nginx master:     ~5 MB                                   │
│  nginx workers:    ~5 MB (1 worker)                       │
│  LiteLLM:          ~400-600 MB (optimized config)         │
│  ──────────────────────────────────────────────────────   │
│  TOTAL ACTIVE:     ~400-600 MB + request overhead         │
└────────────────────────────────────────────────────────────┘
```

### Latency Analysis

| Operation | Always-On | On-Demand (Cold) | On-Demand (Warm) |
|-----------|-----------|------------------|------------------|
| Wrapper start | N/A | ~50ms | ~50ms |
| Backend start | N/A | 3-10s | N/A |
| Health check | N/A | ~100ms | ~10ms |
| First request | <100ms | 3-10s | <100ms |
| Subsequent | <100ms | <100ms | <100ms |

### Cost Analysis (Estimated Monthly)

Assumptions:
- Electricity: $0.12/kWh
- Server: 65W idle, 95W active
- Usage: 8 hours/day active, 16 hours/day idle

| Mode | Daily Energy | Monthly Cost | Annual Cost |
|------|-------------|--------------|-------------|
| Always-On | 2.16 kWh | $7.78 | $93.31 |
| On-Demand | 1.04 kWh | $3.74 | $44.93 |
| **Savings** | **52%** | **$4.04** | **$48.38** |

> Note: Actual savings depend on hardware, usage patterns, and electricity rates.

---

## When to Use Each Mode

### Use On-Demand (Default) When:

✅ **Individual developers** - Coding sessions with breaks
✅ **Laptop/portable development** - Battery life matters
✅ **Shared servers** - Multiple users, not simultaneous
✅ **Cost-conscious environments** - Cloud VMs, pay-per-use
✅ **Intermittent CI/CD** - Scheduled builds, not continuous
✅ **Learning/experimentation** - Occasional use

### Use Always-On When:

✅ **Team shared server** - Multiple concurrent developers
✅ **CI/CD pipelines** - Frequent automated runs
✅ **Real-time applications** - Chatbots, assistants requiring instant response
✅ **High-frequency API usage** - >10 requests/minute sustained
✅ **Latency-sensitive workflows** - Sub-second response required
✅ **Kubernetes/Docker Swarm** - Orchestrated environments with health checks

---

## Switching Between Modes

### Enable Always-On
```bash
# Option 1: Via .env (persistent)
echo "MYCLAUDE_IDLE_TIMEOUT=0" >> /home/ML/myclaude/.env
sudo systemctl restart myclaude

# Option 2: Via systemd (manual)
sudo systemctl enable --now myclaude
# Then use directly:
ANTHROPIC_BASE_URL=http://localhost:4001 ANTHROPIC_API_KEY=sk-local-proxy-key claude

# Option 3: Docker (always-on by default)
# Remove idle timeout from docker-compose.yml environment
```

### Enable On-Demand
```bash
# Via .env (default)
echo "MYCLAUDE_IDLE_TIMEOUT=300" >> /home/ML/myclaude/.env  # 5 min
sudo systemctl daemon-reload
sudo systemctl restart myclaude

# Verify
grep Restart /etc/systemd/system/myclaude.service
# Must show: Restart=on-failure
```

### Temporary Override
```bash
# Single session with different timeout
MYCLAUDE_IDLE_TIMEOUT=600 myclaude

# Disable for current session only
MYCLAUDE_IDLE_TIMEOUT=0 myclaude
```

---

## Migration Guide

### From Always-On to On-Demand

1. **Update systemd service**
   ```bash
   # Ensure Restart=on-failure
   sudo sed -i 's/Restart=always/Restart=on-failure/' /etc/systemd/system/myclaude.service
   sudo systemctl daemon-reload
   ```

2. **Configure idle timeout**
   ```bash
   echo "MYCLAUDE_IDLE_TIMEOUT=300" >> /home/ML/myclaude/.env
   ```

3. **Optimize nginx for on-demand**
   ```bash
   sudo sed -i 's/worker_processes auto;/worker_processes 1;/' /etc/nginx/nginx.conf
   sudo nginx -t && sudo systemctl reload nginx
   ```

4. **Update LiteLLM config**
   ```yaml
   # config.yaml
   litellm_settings:
     cache: false
     log_level: "WARNING"
   router_settings:
     health_check_interval: 300
   ```

5. **Restart and test**
   ```bash
   sudo systemctl restart myclaude
   myclaude --version  # Test startup
   ```

### From On-Demand to Always-On

1. **Disable idle timeout**
   ```bash
   echo "MYCLAUDE_IDLE_TIMEOUT=0" >> /home/ML/myclaude/.env
   ```

2. **Restore systemd restart policy**
   ```bash
   sudo sed -i 's/Restart=on-failure/Restart=always/' /etc/systemd/system/myclaude.service
   sudo systemctl daemon-reload
   ```

3. **Restore nginx workers**
   ```bash
   sudo sed -i 's/worker_processes 1;/worker_processes auto;/' /etc/nginx/nginx.conf
   sudo nginx -t && sudo systemctl reload nginx
   ```

4. **Restore LiteLLM optimizations**
   ```yaml
   # config.yaml
   litellm_settings:
     cache: true
     log_level: "INFO"
   router_settings:
     health_check_interval: 30
   ```

---

## Decision Matrix

| Factor | Weight | Always-On Score | On-Demand Score |
|--------|--------|-----------------|-----------------|
| RAM Efficiency | High | 2/10 | 10/10 |
| First Response Latency | High | 10/10 | 4/10 |
| Subsequent Latency | High | 10/10 | 10/10 |
| Power Consumption | Medium | 3/10 | 9/10 |
| Concurrent Users | High | 10/10 | 6/10 |
| Operational Simplicity | Medium | 8/10 | 7/10 |
| Cost (Cloud) | Medium | 4/10 | 9/10 |
| Predictability | Medium | 9/10 | 6/10 |
| **Weighted Total** | | **6.7/10** | **8.1/10** |

> **Recommendation**: On-Demand wins for most individual and small team use cases. Always-On for production teams and CI/CD.

---

## Hybrid Approach

For teams wanting the best of both worlds:

```bash
# Core hours (9am-6pm): Always-on
# Off hours: On-demand with short timeout

# Via cron:
0 9 * * 1-5 echo "MYCLAUDE_IDLE_TIMEOUT=0" > /home/ML/myclaude/.env && systemctl reload myclaude
0 18 * * 1-5 echo "MYCLAUDE_IDLE_TIMEOUT=300" > /home/ML/myclaude/.env && systemctl reload myclaude
```

Or use a wrapper script:
```bash
#!/bin/bash
# smart-myclaude.sh
HOUR=$(date +%H)
if [ "$HOUR" -ge 9 ] && [ "$HOUR" -lt 18 ]; then
    export MYCLAUDE_IDLE_TIMEOUT=0
else
    export MYCLAUDE_IDLE_TIMEOUT=300
fi
exec /usr/local/bin/myclaude "$@"
```

---

## Future Considerations

### Planned Enhancements

1. **Predictive startup** - Learn usage patterns, pre-warm before expected use
2. **Gradual scale-down** - Reduce workers before full shutdown
3. **Model-level on-demand** - Load only requested model, not all 4
4. **Metrics-based scaling** - Auto-adjust timeout based on usage patterns

### Roadmap Impact

| Feature | Always-On Impact | On-Demand Impact |
|---------|------------------|------------------|
| Model unloading | Low (always loaded) | High (major RAM savings) |
| Predictive startup | N/A | High (eliminates cold start) |
| Gradual scale-down | Medium | High (smoother transitions) |
| Multi-model routing | Same | Same |

---

## Conclusion

**On-Demand is the recommended default** for MyClaude because:

1. **50%+ RAM reduction** when idle
2. **Instant subsequent requests** after first startup
3. **Configurable timeout** adapts to any workflow
4. **Docker-native** with same behavior in containers
5. **Zero-cost switching** to always-on when needed

The 3-10 second cold start is a one-time cost per session that pays back immediately in resource savings for any workflow with breaks longer than 5 minutes.