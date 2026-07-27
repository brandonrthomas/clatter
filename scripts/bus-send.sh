#!/usr/bin/env bash
# Send a message to another session's mailbox (local, or over ssh to a peer machine).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

reply_to="" from="${BUS_SELF:-}" pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --reply-to) reply_to="$2"; shift 2 ;;
    --from)     from="$2";     shift 2 ;;
    *) pos+=("$1"); shift ;;
  esac
done
target="${pos[0]:-}"; type="${pos[1]:-}"; subject="${pos[2]:-}"; body="${pos[3]:-}"
if [ -z "$target" ] || [ -z "$type" ]; then
  echo "usage: bus-send.sh <target[@machine]> <query|response|notify|broadcast> <subject> <body> [--reply-to id] [--from name]" >&2
  exit 1
fi
# Optional explicit routing: target@machine sends over SSH to <machine> (an ssh host/alias).
target_machine=""
case "$target" in
  *@*) target_machine="${target##*@}"; target="${target%@*}" ;;
esac
# target/machine become filesystem paths and parts of an ssh command line — constrain both so they
# can't traverse paths or inject a remote shell. (broadcast's placeholder "_" passes.)
case "$target" in
  ''|*[!A-Za-z0-9_-]*) echo "bus-send: invalid target name '$target'" >&2; exit 1 ;;
esac
case "$target_machine" in
  *[!A-Za-z0-9_.-]*) echo "bus-send: invalid machine '$target_machine'" >&2; exit 1 ;;
esac

# Resolve own name if not given: match a registry entry to this session's claude pid.
if [ -z "$from" ]; then
  mypid="$(bus_find_claude_pid "$$" || true)"
  if [ -n "$mypid" ]; then
    for f in "$BUS_REG"/*.json; do
      [ -e "$f" ] || continue
      [ "$(jq -r '.pid' "$f" 2>/dev/null)" = "$mypid" ] && { from="$(basename "$f" .json)"; break; }
    done
  fi
fi
[ -z "$from" ] && from="$(basename "$(pwd)")"

id="$(date +%s%3N)-$(printf '%04x' $((RANDOM)))"
ts="$(date -Is)"

# broadcast: fan out as notify to every other live session
if [ "$type" = "broadcast" ]; then
  for f in "$BUS_REG"/*.json; do
    [ -e "$f" ] || continue
    t="$(basename "$f" .json)"
    [ "$t" = "$from" ] && continue
    "$0" "$t" notify "$subject" "$body" --from "$from"
  done
  exit 0
fi

# Where does the target live? explicit @machine wins; else the local registry; else search peer
# hosts (cross-machine discovery); else default to this machine.
tmachine="$BUS_SELF_MACHINE"
if [ -n "$target_machine" ]; then
  tmachine="$target_machine"
elif [ -f "$BUS_REG/$target.json" ]; then
  tmachine="$(jq -r '.machine' "$BUS_REG/$target.json")"
elif [ "$type" != "broadcast" ] && [ -f "$BUS_ROOT/peers" ]; then
  # Not a local session: look for it on a peer host (first match wins; use name@machine to force one).
  while IFS= read -r m; do
    m="${m%%#*}"; m="$(printf '%s' "$m" | tr -d '[:space:]')"; [ -z "$m" ] && continue
    if $BUS_SSH "$m" \
         "test -f \"\${CLAUDEMUX_ROOT:-\$HOME/.claude/claudemux}/registry/$target.json\"" </dev/null 2>/dev/null; then
      tmachine="$m"; break
    fi
  done < "$BUS_ROOT/peers"
fi

# Fail fast on an unknown target instead of dropping a message the relay will never wake.
if [ -z "$target_machine" ] && [ "$tmachine" = "$BUS_SELF_MACHINE" ] && [ ! -f "$BUS_REG/$target.json" ]; then
  echo "bus-send: no session named '$target' found (local or on peers)" >&2
  exit 1
fi

build_msg() {
  jq -n \
    --arg id "$id" --arg from "$from" --arg to "$target" --arg machine "$BUS_SELF_MACHINE" \
    --arg type "$type" --arg subject "$subject" --arg body "$body" \
    --arg reply_to "$reply_to" --arg ts "$ts" \
    '{id:$id, from:$from, to:$to, machine:$machine, type:$type, subject:$subject,
      body:$body, reply_to:(if $reply_to=="" then null else $reply_to end), timestamp:$ts}'
}

if [ -z "$tmachine" ] || [ "$tmachine" = "null" ] || [ "$tmachine" = "$BUS_SELF_MACHINE" ]; then
  mkdir -p "$BUS_MBX/$target/archive"
  tmp="$BUS_MBX/$target/.$id.tmp"
  build_msg > "$tmp"
  mv "$tmp" "$BUS_MBX/$target/$id.json"
  echo "sent $type -> $target (id $id)"
else
  # Remote peer: atomic tmp+rename drop over ssh. The mailbox path is computed on the REMOTE side
  # from its own $CLAUDEMUX_ROOT/$HOME, so machines with different home dirs work. target/id are
  # charset-validated above, so they are safe to interpolate into the remote command.
  build_msg | $BUS_SSH "$tmachine" \
    "R=\"\${CLAUDEMUX_ROOT:-\$HOME/.claude/claudemux}\"; d=\"\$R/mailbox/$target\"; \
     mkdir -p \"\$d/archive\" && cat > \"\$d/.$id.tmp\" && mv \"\$d/.$id.tmp\" \"\$d/$id.json\""
  echo "sent $type -> $target@$tmachine (id $id)"
fi
