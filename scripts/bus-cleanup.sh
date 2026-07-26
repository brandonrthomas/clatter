#!/usr/bin/env bash
# Prune registry entries whose pid is no longer alive.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

shopt -s nullglob
for f in "$BUS_REG"/*.json; do
  pid=$(jq -r '.pid' "$f" 2>/dev/null || echo "")
  if [ -n "$pid" ] && [ "$pid" != "null" ] && ! bus_alive "$pid"; then
    echo "pruning dead session: $(basename "$f" .json) (pid $pid)"
    rm -f "$f"
  fi
done
