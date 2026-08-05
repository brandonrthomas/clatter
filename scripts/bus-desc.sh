#!/usr/bin/env bash
# Show or set a session's free-text description (shown in the DESC column of /cm peers).
#   bus-desc.sh                  -> print this session's description
#   bus-desc.sh <text...>        -> set it (all words joined)
#   bus-desc.sh --clear          -> remove it
#   bus-desc.sh --sid SID <text> -> target a specific sessionId (another local session / testing)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

sid=""
if [ "${1:-}" = "--sid" ]; then sid="${2:-}"; shift 2 || true; fi
[ -z "$sid" ] && sid="$(bus_self_sid || true)"
[ -z "$sid" ] && { echo "this session is not registered on the bus"; exit 0; }
case "$sid" in *[!A-Za-z0-9_-]*) echo "bus-desc: invalid sessionId '$sid'" >&2; exit 1 ;; esac
f="$BUS_REG/$sid.json"
[ -f "$f" ] || { echo "bus-desc: no registry entry for $sid" >&2; exit 1; }

want="$*"; want="${want//$'\t'/ }"; want="${want//$'\n'/ }"
if [ -z "$want" ]; then
  cur="$(jq -r '.desc // ""' "$f")"
  [ -n "$cur" ] && echo "description: $cur" || echo "(no description set — /cm desc <text> to set one)"
  exit 0
fi
[ "$want" = "--clear" ] && want=""

tmp="$f.tmp.$$"
jq --arg d "$want" '.desc=$d' "$f" > "$tmp" && mv "$tmp" "$f"
[ -n "$want" ] && echo "description set: $want" || echo "description cleared"
