#!/usr/bin/env bash
# Shared paths + helpers for the session bus. Sourced by every bus-*.sh and the relay.

BUS_ROOT="${CLAUDEMUX_ROOT:-$HOME/.claude/claudemux}"
BUS_REG="$BUS_ROOT/registry"
BUS_MBX="$BUS_ROOT/mailbox"
BUS_SELF_MACHINE="${CLAUDEMUX_MACHINE:-$(hostname -s)}"

# Walk up the process tree from $1 (default $$) to the nearest `claude` process; echo its pid.
# Claude Code is a node app, so match on args (starts with claude / */claude), not comm (=node).
bus_find_claude_pid() {
  local pid="${1:-$$}" args ppid
  while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    case "$args" in
      claude|claude\ *|*/claude|*/claude\ *) echo "$pid"; return 0 ;;
    esac
    ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -z "$ppid" ] && break
    pid="$ppid"
  done
  return 1
}

# pid -> /dev/pts/N (the tty the process is bound to). Empty/fail if none.
bus_pid_to_tty() {
  local t
  t=$(ps -o tty= -p "$1" 2>/dev/null | tr -d ' ')
  if [ -z "$t" ] || [ "$t" = "?" ]; then return 1; fi
  echo "/dev/$t"
}

# tty (/dev/pts/N) -> tmux pane id (%N), resolved live against the running server.
bus_tty_to_pane() {
  tmux list-panes -a -F '#{pane_tty} #{pane_id}' 2>/dev/null \
    | awk -v t="$1" '$1==t{print $2; exit}'
}

# is pid alive?
bus_alive() { kill -0 "$1" 2>/dev/null; }

# Resolve THIS session's registered bus name by matching its claude pid to a registry entry.
# Works from any bash child of the session (hook, slash-command exec, manual).
bus_resolve_self_name() {
  local mypid f
  mypid="$(bus_find_claude_pid "${1:-$$}" || true)"
  [ -n "$mypid" ] || return 1
  for f in "$BUS_REG"/*.json; do
    [ -e "$f" ] || continue
    if [ "$(jq -r '.pid' "$f" 2>/dev/null)" = "$mypid" ]; then
      basename "$f" .json
      return 0
    fi
  done
  return 1
}
