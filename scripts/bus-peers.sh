#!/usr/bin/env bash
# List sessions on the bus with their LIVE names (resolved from Claude's session files each call).
#   default : human table — local, then each peer host in $CLAUDEMUX_ROOT/peers (over ssh).
#   --json  : local entries only, one JSON object per line (used for remote aggregation).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"
shopt -s nullglob

if [ "${1:-}" = "--json" ]; then
  for f in "$BUS_REG"/*.json; do
    pid=$(jq -r '.pid' "$f"); if bus_alive "$pid"; then al=true; else al=false; fi
    name="$(bus_display_name "$f")"
    jq -c --arg name "$name" --argjson alive "$al" \
      '{name:$name, sessionId:.sessionId, machine:.machine, mode:.mode, alive:$alive}' "$f"
  done
  exit 0
fi

row() { printf '%-20s %-8s %-6s %s\n' "$1" "$2" "$3" "$4"; }
row NAME MACHINE ALIVE MODE

for f in "$BUS_REG"/*.json; do
  pid=$(jq -r '.pid' "$f"); machine=$(jq -r '.machine' "$f"); mode=$(jq -r '.mode' "$f")
  if bus_alive "$pid"; then al=yes; else al=DEAD; fi
  row "$(bus_display_name "$f")" "$machine" "$al" "$mode"
done

pf="$BUS_ROOT/peers"
[ -f "$pf" ] || exit 0
while IFS= read -r m; do
  m="${m%%#*}"; m="$(printf '%s' "$m" | tr -d '[:space:]')"; [ -z "$m" ] && continue
  # capture with `|| true` (+ </dev/null so ssh doesn't eat the peers-file loop stdin)
  jlines="$($BUS_SSH "$m" 'bash "${CLAUDEMUX_ROOT:-$HOME/.claude/claudemux}/scripts/bus-peers.sh" --json' </dev/null 2>/dev/null || true)"
  [ -z "$jlines" ] && continue
  while IFS= read -r j; do
    [ -z "$j" ] && continue
    name=$(printf '%s' "$j" | jq -r '.name'); mode=$(printf '%s' "$j" | jq -r '.mode')
    al=$(printf '%s' "$j" | jq -r 'if .alive then "yes" else "DEAD" end')
    row "${name}@${m}" "$m" "$al" "$mode"
  done <<< "$jlines"
done < "$pf"
