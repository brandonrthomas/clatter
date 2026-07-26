#!/usr/bin/env bash
# Register this session in the bus registry. With --name it's explicit; without, the name is
# auto-derived from cwd basename (collision-suffixed, and this pid's existing entry is reused
# on a re-run so SessionStart on resume/clear doesn't mint a duplicate).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

name="" desc="" mode="auto" pid=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) name="$2"; shift 2 ;;
    --desc) desc="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;   # auto (relay may wake) | manual (never send-keys)
    --pid)  pid="$2";  shift 2 ;;
    *) [ -z "$name" ] && name="$1"; shift ;;
  esac
done

[ -z "$pid" ] && pid="$(bus_find_claude_pid "$$" || true)"
[ -z "$pid" ] && { echo "could not resolve claude pid; pass --pid" >&2; exit 1; }
tty="$(bus_pid_to_tty "$pid" || true)"
cwd="$(pwd)"
started="$(date -Is)"
mkdir -p "$BUS_REG"

# Auto-name: reuse this pid's existing entry if any, else basename(cwd), suffixed on live collision.
if [ -z "$name" ]; then
  for f in "$BUS_REG"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.pid' "$f" 2>/dev/null)" = "$pid" ] && { name="$(basename "$f" .json)"; break; }
  done
fi
if [ -z "$name" ]; then
  base="$(basename "$cwd" | tr -c 'A-Za-z0-9_-' '-' | sed 's/^-*//; s/-*$//')"
  [ -z "$base" ] && base="session"
  name="$base"; n=1
  while [ -f "$BUS_REG/$name.json" ]; do
    op="$(jq -r '.pid' "$BUS_REG/$name.json" 2>/dev/null)"
    if [ -z "$op" ] || [ "$op" = "null" ] || [ "$op" = "$pid" ] || ! bus_alive "$op"; then break; fi
    n=$((n+1)); name="$base-$n"
  done
fi
name="$(printf '%s' "$name" | tr -c 'A-Za-z0-9_-' '-')"   # sanitize (also constrains explicit names)

mkdir -p "$BUS_MBX/$name/archive"
tmp="$BUS_REG/.$name.$$.tmp"
jq -n \
  --arg name "$name" --arg machine "$BUS_SELF_MACHINE" --argjson pid "$pid" \
  --arg tty "$tty" --arg cwd "$cwd" --arg started "$started" --arg desc "$desc" --arg mode "$mode" \
  '{name:$name, machine:$machine, pid:$pid, tty:$tty, cwd:$cwd, started:$started, description:$desc, mode:$mode}' \
  > "$tmp"
mv "$tmp" "$BUS_REG/$name.json"
echo "registered '$name' (pid $pid, tty ${tty:-none}, mode $mode)"
