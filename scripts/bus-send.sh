#!/usr/bin/env bash
# Send a message. Target is a human NAME (resolved live to a sessionId) or a sessionId directly,
# optionally @machine. Mailboxes are keyed by sessionId, so a peer renaming itself never misroutes.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

reply_to="" from="" from_session_arg="" pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reply-to)     reply_to="$2"; shift 2 ;;
    --from)         from="$2"; shift 2 ;;
    --from-session) from_session_arg="$2"; shift 2 ;;
    *) pos+=("$1"); shift ;;
  esac
done
target="${pos[0]:-}"; type="${pos[1]:-}"; subject="${pos[2]:-}"; body="${pos[3]:-}"
if [ -z "$target" ] || [ -z "$type" ]; then
  echo "usage: bus-send.sh <name|sessionId[@machine]> <query|response|notify|broadcast> <subject> <body> [--reply-to id] [--from name]" >&2
  exit 1
fi

tmachine=""
case "$target" in *@*) tmachine="${target##*@}"; target="${target%@*}" ;; esac
case "$tmachine" in *[!A-Za-z0-9_.-]*) echo "bus-send: invalid machine '$tmachine'" >&2; exit 1 ;; esac

# --- sender identity (live) ---
from_session="${from_session_arg:-$(bus_self_sid || true)}"; [ -z "$from_session" ] && from_session="unknown"
[ -z "$from" ] && from="$(bus_self_name)"
# A query expects a reply, so it needs a repliable sender. Refuse to send one from a context we
# can't identify (e.g. outside a registered session) rather than emit an unrepliable message.
if [ "$type" = "query" ] && [ "$from_session" = "unknown" ]; then
  echo "bus-send: refusing to send a query with no repliable sender (this session isn't on the bus)" >&2
  exit 1
fi

id="$(date +%s%3N)-$(printf '%04x' $((RANDOM)))"
ts="$(date -Is)"

# --- broadcast: to every live LOCAL session (by sessionId) except self ---
if [ "$type" = "broadcast" ]; then
  shopt -s nullglob
  for f in "$BUS_REG"/*.json; do
    s="$(jq -r '.sessionId' "$f" 2>/dev/null)"; [ "$s" = "$from_session" ] && continue
    bus_alive "$(jq -r '.pid' "$f" 2>/dev/null)" || continue
    "$0" "$s" notify "$subject" "$body" --from "$from"
  done
  exit 0
fi

# --- resolve target -> (to_session, tmachine) ---
to_session=""
if bus_is_uuid "$target"; then
  to_session="$target"; [ -z "$tmachine" ] && tmachine="$BUS_SELF_MACHINE"
elif [ -n "$tmachine" ] && [ "$tmachine" != "$BUS_SELF_MACHINE" ]; then
  # name on an explicit remote machine (name piped in — never interpolated into the remote command)
  to_session="$(printf '%s' "$target" | $BUS_SSH "$tmachine" 'bash "${CLAUDEMUX_ROOT:-$HOME/.claude/claudemux}/scripts/bus-resolve.sh" --stdin' 2>/dev/null || true)"
else
  to_session="$("$DIR/bus-resolve.sh" "$target" 2>/dev/null || true)"
  if [ -n "$to_session" ]; then
    tmachine="$BUS_SELF_MACHINE"
  elif [ -f "$BUS_ROOT/peers" ]; then
    while IFS= read -r m; do
      m="${m%%#*}"; m="$(printf '%s' "$m" | tr -d '[:space:]')"; [ -z "$m" ] && continue
      r="$(printf '%s' "$target" | $BUS_SSH "$m" 'bash "${CLAUDEMUX_ROOT:-$HOME/.claude/claudemux}/scripts/bus-resolve.sh" --stdin' 2>/dev/null || true)"
      [ -n "$r" ] && { to_session="$r"; tmachine="$m"; break; }
    done < "$BUS_ROOT/peers"
  fi
fi
[ -z "$to_session" ] && { echo "bus-send: no session '${target}'${tmachine:+@$tmachine} found (local or on peers)" >&2; exit 1; }
case "$to_session" in *[!A-Za-z0-9_-]*) echo "bus-send: resolved unsafe sessionId '$to_session'" >&2; exit 1 ;; esac

build_msg() {
  jq -n --arg id "$id" --arg from "$from" --arg fs "$from_session" --arg to "$to_session" \
        --arg machine "$BUS_SELF_MACHINE" --arg type "$type" --arg subject "$subject" --arg body "$body" \
        --arg reply_to "$reply_to" --arg ts "$ts" \
    '{id:$id, from:$from, from_session:$fs, to_session:$to, machine:$machine, type:$type,
      subject:$subject, body:$body, reply_to:(if $reply_to=="" then null else $reply_to end), timestamp:$ts}'
}

if [ -z "$tmachine" ] || [ "$tmachine" = "$BUS_SELF_MACHINE" ]; then
  mkdir -p "$BUS_MBX/$to_session/archive"
  tmp="$BUS_MBX/$to_session/.$id.tmp"; build_msg > "$tmp"; mv "$tmp" "$BUS_MBX/$to_session/$id.json"
  echo "sent $type -> $target (session $to_session, id $id)"
else
  build_msg | $BUS_SSH "$tmachine" \
    "R=\"\${CLAUDEMUX_ROOT:-\$HOME/.claude/claudemux}\"; d=\"\$R/mailbox/$to_session\"; \
     mkdir -p \"\$d/archive\" && cat > \"\$d/.$id.tmp\" && mv \"\$d/.$id.tmp\" \"\$d/$id.json\""
  echo "sent $type -> $target@$tmachine (session $to_session, id $id)"
fi
