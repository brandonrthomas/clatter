#!/usr/bin/env bash
# Register this session on the bus, keyed by its Claude sessionId (stable). The human name is NOT
# stored here — it's resolved live from Claude's session file at display/address time.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

sid="" pid="" mode="auto" cwd="" machine="$BUS_SELF_MACHINE"
while [ $# -gt 0 ]; do
  case "$1" in
    --sessionid) sid="$2"; shift 2 ;;
    --pid)       pid="$2"; shift 2 ;;
    --mode)      mode="$2"; shift 2 ;;
    --cwd)       cwd="$2"; shift 2 ;;
    --machine)   machine="$2"; shift 2 ;;
    *) shift ;;
  esac
done

[ -z "$pid" ] && pid="$(bus_find_claude_pid "$$" || true)"
[ -z "$pid" ] && { echo "bus-register: could not resolve claude pid; pass --pid" >&2; exit 1; }
[ -z "$sid" ] && sid="$(bus_sessionid_of_pid "$pid")"
[ -z "$sid" ] && { echo "bus-register: could not resolve sessionId for pid $pid; pass --sessionid" >&2; exit 1; }
[ -z "$cwd" ] && cwd="$(pwd)"
case "$sid" in ''|*[!A-Za-z0-9_-]*) echo "bus-register: unsafe sessionId '$sid'" >&2; exit 1 ;; esac

mkdir -p "$BUS_REG" "$BUS_MBX/$sid/archive"
tmp="$BUS_REG/.$sid.$$.tmp"
jq -n --arg sid "$sid" --argjson pid "$pid" --arg machine "$machine" --arg cwd "$cwd" \
      --arg mode "$mode" --arg started "$(date -Is)" \
  '{sessionId:$sid, pid:$pid, machine:$machine, cwd:$cwd, mode:$mode, started:$started}' > "$tmp"
mv "$tmp" "$BUS_REG/$sid.json"
name="$(bus_name_of_pid "$pid")"; [ -n "$name" ] || name="$(basename "$cwd")"
echo "registered '$name' (session $sid, pid $pid, mode $mode)"
