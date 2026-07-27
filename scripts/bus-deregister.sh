#!/usr/bin/env bash
# Remove a session's manifest. Arg is a sessionId, or a name (resolved live). No arg = this session.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

arg="${1:-}"
if [ -z "$arg" ]; then
  sid="$(bus_self_sid || true)"
elif bus_is_uuid "$arg"; then
  sid="$arg"
else
  sid="$("$DIR/bus-resolve.sh" "$arg" 2>/dev/null || true)"
fi
[ -z "${sid:-}" ] && { echo "bus-deregister: could not resolve a session to remove" >&2; exit 1; }
rm -f "$BUS_REG/$sid.json"
echo "deregistered session $sid"
