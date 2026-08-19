#!/bin/bash
# Health check for MyClaude Docker container

# Check nginx health endpoint (full proxy stack)
if curl -s --max-time 2 -f "http://localhost:4000/health" >/dev/null 2>&1; then
    exit 0
fi

# Fallback: check if LiteLLM is directly responsive
if curl -s --max-time 2 -f "http://localhost:4001/health" >/dev/null 2>&1; then
    exit 0
fi

exit 1