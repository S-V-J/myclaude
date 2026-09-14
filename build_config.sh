#!/bin/bash
# build_config.sh - Combines modular YAML files into the final config.yaml for LiteLLM
echo "🔨 Building config.yaml from modular scene files..."

# 1. Start with the base configuration
cat config_base.yaml > config.yaml

# 2. Append model configurations for the 4 scenarios
cat models/scene_1_default.yaml >> config.yaml
cat models/scene_2_opus_1m.yaml >> config.yaml
cat models/scene_3_sonnet.yaml >> config.yaml
cat models/scene_4_sonnet_1m.yaml >> config.yaml

echo "✅ config.yaml successfully built with 4 fallback chains!"
