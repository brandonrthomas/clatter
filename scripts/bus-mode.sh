#!/usr/bin/env bash
# Show or set a session's bus mode. auto = the relay may wake it (needs a tmux pane); manual = the
# relay never types into it (drain by hand with /cm recv). The relay reads mode at wake time, so a
# change takes effect immediately — no restart. (mode is otherwise fixed when a session registers.)
#   bus-mode.sh                  -> print this session's current mode
#   bus-mode.sh auto|manual      -> set this session's mode
#   bus-mode.sh auto|manual SID  -> set a specific sessionId's mode (another local session / testing)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

want="${1:-}"; sid="${2:-}"
[ -z "$sid" ] && sid="$(bus_self_sid || true)"
[ -z "$sid" ] && { echo "this session is not registered on the bus"; exit 0; }
case "$sid" in *[!A-Za-z0-9_-]*) echo "bus-mode: invalid sessionId '$sid'" >&2; exit 1 ;; esac
f="$BUS_REG/$sid.json"
[ -f "$f" ] || { echo "bus-mode: no registry entry for $sid" >&2; exit 1; }

cur="$(jq -r '.mode // "auto"' "$f")"
if [ -z "$want" ]; then
  echo "current mode: $cur  (session $sid)"; exit 0
fi
case "$want" in auto|manual) ;; *) echo "usage: /cm mode [auto|manual]" >&2; exit 1 ;; esac
if [ "$want" = "$cur" ]; then echo "already $cur"; exit 0; fi

tmp="$f.tmp.$$"
jq --arg m "$want" '.mode=$m' "$f" > "$tmp" && mv "$tmp" "$f"
echo "mode: $cur -> $want  (session $sid)"
[ "$want" = manual ] && echo "  the relay will no longer wake this session — drain it yourself with /cm recv."
[ "$want" = auto ]   && echo "  the relay may now wake this session (requires it to be in a tmux pane)."
