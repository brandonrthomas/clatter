#!/usr/bin/env bash
# Resolve a human session NAME to a LOCAL sessionId, using live names (first live match wins).
# Prints the sessionId, or nothing if no live local session currently has that name.
# Read the name from argv, or from stdin with --stdin (used over SSH so names are never
# interpolated into a remote command line).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

want="${1:-}"
[ "$want" = "--stdin" ] && want="$(cat)"
[ -z "$want" ] && exit 0

shopt -s nullglob
for f in "$BUS_REG"/*.json; do
  bus_alive "$(jq -r '.pid' "$f" 2>/dev/null)" || continue
  if [ "$(bus_display_name "$f")" = "$want" ]; then
    jq -r '.sessionId' "$f"
    exit 0
  fi
done
exit 0
