## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                        User / Claude Code                           │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    myclaude.sh (launcher)                           │
│  • Startup lock • Port discovery • Config rebuild                  │
│  • systemd update • nginx config • Health checks                   │
│  • Auto-recovery • Idle timeout • exec claude                      │
└─────────────────────────────────┬───────────────────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    ▼                           ▼
        ┌───────────────────┐         ┌───────────────────┐
        │    nginx          │         │    systemd        │
        │  (reverse proxy)  │         │  (LiteLLM proxy)  │
        │  Port: NGINX_PORT │         │  Port: LITELLM_P. │
        └─────────┬─────────┘         └─────────┬─────────┘
                  │                             │
                  │ Rate limiting               │
                  │ 16r/s global                │
                  │ 30r/m per API key           │
                  ▼                             ▼
        ┌───────────────────┐         ┌───────────────────┐
        │  /health          │         │  LiteLLM Proxy    │
        │  /health/litellm  │         │  config.yaml      │
        │  /metrics         │         │  4 scenarios ×    │
        │  Admin blocking   │         │  5-model chains   │
        └───────────────────┘         └─────────┬─────────┘
                                                │
                    ┌───────────────────────────┼───────────────────────────┐
                    ▼                           ▼                           ▼
           ┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
           │ Scene 1: Default│         │ Scene 2: Opus   │         │ Scene 3: Sonnet │
           │ claude-opus-5   │         │ 1M              │         │                 │
           │ Key1→2→3→4→1    │         │ Key2→3→4→1→2    │         │ Key3→4→1→2→3    │
           └────────┬────────┘         └────────┬────────┘         └────────┬────────┘
                    │                           │                           │
           ┌────────┴────────┐         ┌────────┴────────┐         ┌────────┴────────┐
           │ 5-Model Chain   │         │ 5-Model Chain   │         │ 5-Model Chain   │
           │ Ultra→Super→    │         │ Ultra→Super→    │         │ Ultra→Super→    │
           │ Nano→Laguna→    │         │ Nano→Laguna→    │         │ Nano→Laguna→    │
           │ Ultra           │         │ Ultra           │         │ Ultra           │
           └─────────────────┘         └─────────────────┘         └─────────────────┘
                    │                           │                           │
                    └───────────────────────────┼───────────────────────────┘
                                                ▼
                                    ┌─────────────────────────┐
                                    │   NVIDIA NIM API        │
                                    │   (Nemotron 3 Ultra,    │
                                    │   Super, Nano, Laguna)  │
                                    └─────────────────────────┘
```

---

## Security Features

| Layer | Implementation |
|-------|----------------|
| **systemd** | `NoNewPrivileges=true`, `PrivateTmp=true`, `ProtectSystem=strict`, `ProtectHome=read-only`, `ReadWritePaths=logs` |
| **nginx** | Security headers (X-Content-Type-Options, X-Frame-Options, Referrer-Policy), admin path blocking, IP-restricted metrics |
| **Rate Limiting** | Global 16r/s + per-API-key 30r/m (via nginx map on Authorization header) |
| **File Permissions** | `.env` = 640, install dir = 750, owned by service user |
| **TLS** | TLS 1.2/1.3 only, modern ciphers, HSTS, OCSP stapling (when enabled) |

---

## License

MIT License

© 2026 MyClaude Project