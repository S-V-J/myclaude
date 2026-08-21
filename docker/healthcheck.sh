#!/bin/bash
# MyClaude Docker Health Check
# Checks both nginx and LiteLLM health endpoints

set -euo pipefail

# Check nginx health (port 4000)
if ! curl -s --max-time 2 -f "http://localhost:4000/health" >/dev/null 2>&1; then
    exit 1
fi

# Check LiteLLM health through nginx (port 4000/health/litellm)
if ! curl -s --max-time 2 -f "http://localhost:4000/health/litellm" >/dev/null 2>&1; then
    exit 1
fi

exit 0