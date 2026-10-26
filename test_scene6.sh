#!/bin/bash
# test_scene6.sh - Confirm every scene-6 model_name maps to a catalog-present model.
set -a; source "$(dirname "$0")/.env"; set +a
KEY="$NVIDIA_API_KEY_1"
# Pull the live catalog once
curl -s https://integrate.api.nvidia.com/v1/models -H "Authorization: Bearer $KEY" \
  | python3 -c "import json,sys;print('\n'.join(m['id'] for m in json.load(sys.stdin).get('data',[])))" \
  > /tmp/catalog.txt
echo "Catalog models: $(wc -l < /tmp/catalog.txt)"
echo "----------- scene-6 worker/router model presence -----------"
grep -hoE 'nvidia_nim/[^,}]+' models/scene_6_orchestration.yaml | sed 's#nvidia_nim/##' | sort -u | while read -r m; do
  if grep -qx "$m" /tmp/catalog.txt; then echo "  ✅ $m"; else echo "  ❌ NOT IN CATALOG: $m  (would 404/403)"; fi
done
echo "------------------------------------------------------------"
echo "Any ❌ line = remove/replace that entry in scene_6_orchestration.yaml."
