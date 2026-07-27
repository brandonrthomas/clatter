#!/usr/bin/env bash
# List sessions on the bus.
#   default : human table — LOCAL registry, then each peer host in $CLAUDEMUX_ROOT/peers (over ssh).
#   --json  : LOCAL entries only, one JSON object per line (used for remote aggregation).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"
shopt -s nullglob

if [ "${1:-}" = "--json" ]; then
  for f in "$BUS_REG"/*.json; do
    pid=$(jq -r '.pid' "$f")
    if bus_alive "$pid"; then al=true; else al=false; fi
    jq -c --argjson alive "$al" '{name,machine,pid,mode,description} + {alive:$alive}' "$f"
  done
  exit 0
fi

row() { printf '%-18s %-8s %-6s %s\n' "$1" "$2" "$3" "$4"; }
row NAME MACHINE ALIVE DESCRIPTION

# local sessions
for f in "$BUS_REG"/*.json; do
  name=$(jq -r '.name' "$f"); machine=$(jq -r '.machine' "$f"); pid=$(jq -r '.pid' "$f")
  mode=$(jq -r '.mode' "$f"); desc=$(jq -r '.description' "$f")
  if bus_alive "$pid"; then al=yes; else al=DEAD; fi
  row "$name" "$machine" "$al" "[$mode] $desc"
done

# remote peers listed in $CLAUDEMUX_ROOT/peers (one ssh host/alias per line; # comments)
pf="$BUS_ROOT/peers"
[ -f "$pf" ] || exit 0
while IFS= read -r m; do
  m="${m%%#*}"; m="$(printf '%s' "$m" | tr -d '[:space:]')"; [ -z "$m" ] && continue
  # capture with `|| true` so a slow/unreachable peer never aborts the listing (set -e + pipefail)
  jlines="$($BUS_SSH "$m" 'bash "${CLAUDEMUX_ROOT:-$HOME/.claude/claudemux}/scripts/bus-peers.sh" --json' </dev/null 2>/dev/null || true)"
  [ -z "$jlines" ] && continue
  while IFS= read -r j; do
    [ -z "$j" ] && continue
    name=$(printf '%s' "$j" | jq -r '.name');  mode=$(printf '%s' "$j" | jq -r '.mode')
    desc=$(printf '%s' "$j" | jq -r '.description')
    al=$(printf '%s' "$j" | jq -r 'if .alive then "yes" else "DEAD" end')
    row "${name}@${m}" "$m" "$al" "[$mode] $desc"
  done <<< "$jlines"
done < "$pf"
