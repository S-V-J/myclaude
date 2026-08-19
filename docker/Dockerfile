# Multi-stage Dockerfile for MyClaude On-Demand Proxy
# Stage 1: Build dependencies
FROM python:3.11-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    python3-dev \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Create virtual environment
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install Python packages
COPY config.yaml /tmp/config.yaml
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir 'litellm[proxy]' "fastapi<0.140.0"

# Stage 2: Runtime
FROM python:3.11-slim AS runtime

# Install runtime dependencies only
RUN apt-get update && apt-get install -y --no-install-recommends \
    nginx \
    curl \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy virtual environment from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Create non-root user
RUN useradd --system --no-create-home --shell /usr/sbin/nologin myclaude

# Create directories
RUN mkdir -p /app /var/log/myclaude /tmp/myclaude && \
    chown -R myclaude:myclaude /app /var/log/myclaude /tmp/myclaude

# Copy application files
COPY config.yaml /app/config.yaml
COPY nginx-myclaude.conf /etc/nginx/sites-enabled/myclaude
COPY docker/entrypoint.sh /entrypoint.sh
COPY docker/healthcheck.sh /healthcheck.sh

RUN chmod +x /entrypoint.sh /healthcheck.sh

# Configure nginx
RUN rm -f /etc/nginx/sites-enabled/default && \
    mkdir -p /var/cache/nginx /var/run && \
    chown -R myclaude:myclaude /var/cache/nginx /var/run

# Expose ports
EXPOSE 4000 4001

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD /healthcheck.sh

# Switch to non-root user
USER myclaude

# Set working directory
WORKDIR /app

# Environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    LITELLM_LOG_LEVEL=INFO \
    LITELLM_LOG_FORMAT=json \
    PORT=4001 \
    MYCLAUDE_IDLE_TIMEOUT=300

# Entrypoint
ENTRYPOINT ["/entrypoint.sh"]