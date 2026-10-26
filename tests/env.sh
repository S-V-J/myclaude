#!/usr/bin/env bash
# tests/env.sh — REAL .env loader for interactive shells.
#
# WHY THIS EXISTS: `python3 - <<PY ... os.environ[k]=v PY` mutates a CHILD
# process only. That is exactly what made $LITELLM_MASTER_KEY empty, which made
# every G-series curl send `x-api-key: `, which LiteLLM turned into
# "No api key passed in" -> Prisma ModuleNotFoundError -> opaque HTTP 500.
# Two rounds of "the proxy 500s" were this one bug.
#
#   source tests/env.sh
_MCDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTENV="$_MCDIR/.env"
[ -f "$DOTENV" ] || { echo "❌ $DOTENV missing"; return 1 2>/dev/null || exit 1; }

_eval=$(python3 - "$DOTENV" <<'PY'
import re, shlex, sys
raw = open(sys.argv[1], "rb").read().decode("utf-8-sig", "replace")
raw = raw.replace("\r\n", "\n").replace("\r", "\n")          # CRLF-proof
for line in raw.splitlines():
    line = line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    k, v = k.strip(), v.strip()
    if len(v) > 1 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
        print(f"export {k}={shlex.quote(v)}")
PY
)
[ -n "$_eval" ] || { echo "❌ .env parser emitted 0 exports"; return 1 2>/dev/null || exit 1; }
eval "$_eval"
unset _eval

_n=0; for i in 1 2 3 4 5 6; do eval "[ -n \"\${NVIDIA_API_KEY_$i:-}\" ] && _n=$((_n+1))"; done
NP=$(cat "$_MCDIR/.nginx_port" 2>/dev/null || echo "?")
LP=$(cat "$_MCDIR/.litellm_port" 2>/dev/null || echo "?")
echo "✅ env loaded: $_n/6 NVIDIA keys | master ${#LITELLM_MASTER_KEY} chars | litellm=$LP nginx=$NP"
if [ "$_n" -ne 6 ] || [ -z "${LITELLM_MASTER_KEY:-}" ]; then
  echo "⚠️  INCOMPLETE ENV — do not run probes until fixed"
  return 1 2>/dev/null || exit 1
fi
return 0 2>/dev/null || exit 0
