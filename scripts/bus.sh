#!/usr/bin/env bash
# Dispatcher behind the /cm slash command: peers | ask | send | broadcast | recv | status.
# `recv` is what the relay's wake types (/cm recv) to make a session drain its inbox.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

cmd="${1:-status}"; shift || true
subj_of() { printf '%s' "$1" | tr '\n' ' ' | cut -c1-48; }

case "$cmd" in
  peers)
    "$DIR/bus-peers.sh"
    ;;
  ask)
    target="${1:-}"; shift || true; q="$*"
    { [ -z "$target" ] || [ -z "$q" ]; } && { echo "usage: /cm ask <target> <question>"; exit 1; }
    "$DIR/bus-send.sh" "$target" query "$(subj_of "$q")" "$q"
    echo "(async — keep working; when '$target' answers, the relay wakes this pane with the reply.)"
    ;;
  send|notify)
    target="${1:-}"; shift || true; m="$*"
    { [ -z "$target" ] || [ -z "$m" ]; } && { echo "usage: /cm send <target> <message>"; exit 1; }
    "$DIR/bus-send.sh" "$target" notify "$(subj_of "$m")" "$m"
    ;;
  broadcast)
    m="$*"
    [ -z "$m" ] && { echo "usage: /cm broadcast <message>"; exit 1; }
    "$DIR/bus-send.sh" _ broadcast "$(subj_of "$m")" "$m"
    ;;
  status)
    sid="$(bus_self_sid || true)"
    if [ -z "$sid" ]; then
      echo "this session is not registered on the bus"
    else
      uname="$(bus_unique_name_of_sid "$sid")"; [ -n "$uname" ] || uname="$(bus_self_name)"
      echo "this session: \"$uname\"  (session $sid)"
      pend=$(find "$BUS_MBX/$sid" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)
      echo "pending inbox: $pend message(s)  (run /cm recv to read)"
    fi
    echo; "$DIR/bus-peers.sh"
    ;;
  recv)
    "$DIR/bus-recv.sh"
    ;;
  clear)
    "$DIR/bus-clear.sh"
    ;;
  mode)
    "$DIR/bus-mode.sh" "$@"
    ;;
  desc|describe)
    "$DIR/bus-desc.sh" "$@"
    ;;
  doctor)
    "$DIR/bus-doctor.sh"
    ;;
  *)
    echo "usage: /cm {peers | ask <target> <question> | send <target> <msg> | broadcast <msg> | recv | clear | mode [auto|manual] | desc [text] | status | doctor}"
    exit 1
    ;;
esac
