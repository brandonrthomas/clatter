#!/usr/bin/env bash
# List sessions on the bus with their LIVE, disambiguated names (resolved each call).
#   default : human table — local, then each peer host in $CLAUDEMUX_ROOT/peers (over ssh).
#   --json  : local entries only, one JSON object per line (used for remote aggregation).
# Duplicate names among live local sessions get -2/-3 suffixes (see bus_local_roster).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"
shopt -s nullglob

if [ "${1:-}" = "--json" ]; then
  bus_local_roster | while IFS="$(printf '\t')" read -r sid pid mode name; do
    desc="$(jq -r '.desc // ""' "$BUS_REG/$sid.json" 2>/dev/null || true)"
    jq -cn --arg name "$name" --arg sid "$sid" --arg machine "$BUS_SELF_MACHINE" --arg mode "$mode" --arg desc "$desc" \
      '{name:$name, sessionId:$sid, machine:$machine, mode:$mode, desc:$desc, alive:true}'
  done
  exit 0
fi

row() { printf '%-20s %-8s %-6s %-7s %s\n' "$1" "$2" "$3" "$4" "${5:-}"; }
row NAME MACHINE ALIVE MODE DESC

bus_local_roster | while IFS="$(printf '\t')" read -r sid pid mode name; do
  desc="$(jq -r '.desc // ""' "$BUS_REG/$sid.json" 2>/dev/null || true)"
  row "$name" "$BUS_SELF_MACHINE" yes "$mode" "$desc"
done

pf="$BUS_ROOT/peers"
if [ -f "$pf" ]; then
  while IFS= read -r m; do
    m="${m%%#*}"; m="$(printf '%s' "$m" | tr -d '[:space:]')"; [ -z "$m" ] && continue
    # capture with `|| true` (+ </dev/null so ssh doesn't eat the peers-file loop stdin)
    jlines="$($BUS_SSH "$m" 'bash "${CLAUDEMUX_ROOT:-$HOME/.claude/claudemux}/scripts/bus-peers.sh" --json' </dev/null 2>/dev/null || true)"
    [ -z "$jlines" ] && continue
    while IFS= read -r j; do
      [ -z "$j" ] && continue
      name=$(printf '%s' "$j" | jq -r '.name'); mode=$(printf '%s' "$j" | jq -r '.mode')
      desc=$(printf '%s' "$j" | jq -r '.desc // ""')
      al=$(printf '%s' "$j" | jq -r 'if .alive then "yes" else "DEAD" end')
      row "${name}@${m}" "$m" "$al" "$mode" "$desc"
    done <<< "$jlines"
  done < "$pf"
fi

# Loud flag: a manual-mode guard that currently protects nothing (fails OPEN, silently).
if bus_manual_patterns_orphaned; then
  echo
  echo "⚠ manual-patterns is set but matches NO live session — those globs protect nothing."
  echo "  Run 'cm doctor' to see what they match. (manual-mode guards fail OPEN.)"
fi
