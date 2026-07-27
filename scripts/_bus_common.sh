#!/usr/bin/env bash
# Shared paths + helpers for Claudemux. Sourced by every bus-*.sh and the relay.
#
# Identity model: the STABLE key for a session is its Claude **sessionId** (a UUID) — used for the
# registry filename and the mailbox directory, so it never changes. The human **name** is resolved
# LIVE from Claude's own per-session file (~/.claude/sessions/<pid>.json, which Claude updates on
# /rename), so names can change in real time without re-keying any mailbox.

BUS_ROOT="${CLAUDEMUX_ROOT:-$HOME/.claude/claudemux}"
BUS_REG="$BUS_ROOT/registry"          # <sessionId>.json  (stable key)
BUS_MBX="$BUS_ROOT/mailbox"           # <sessionId>/
BUS_SELF_MACHINE="${CLAUDEMUX_MACHINE:-$(hostname -s)}"
# Claude Code's live per-session files (name/sessionId/status), keyed by pid. Overridable for tests.
BUS_CC_SESSIONS="${CLAUDEMUX_SESSIONS_DIR:-$HOME/.claude/sessions}"
# Claude Code's transcripts (projects/<escaped-cwd>/<sessionId>.jsonl). Renames — local AND from the
# web UI — are appended here as {"type":"custom-title","customTitle":"…"} records, so the latest
# such record is the authoritative live name (the session file's .name lags on web renames).
BUS_CC_PROJECTS="${CLAUDEMUX_PROJECTS_DIR:-$HOME/.claude/projects}"
# ssh for cross-machine ops; timeout tolerates a cold Tailscale connect. Never prompts.
BUS_SSH="ssh -o BatchMode=yes -o ConnectTimeout=${CLAUDEMUX_SSH_TIMEOUT:-8}"

# Walk up the process tree from $1 (default $$) to the nearest `claude` process; echo its pid.
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

# pid -> /dev/pts/N ; empty/fail if none
bus_pid_to_tty() {
  local t; t=$(ps -o tty= -p "$1" 2>/dev/null | tr -d ' ')
  if [ -z "$t" ] || [ "$t" = "?" ]; then return 1; fi
  echo "/dev/$t"
}

# tty -> tmux pane id (%N), resolved live
bus_tty_to_pane() {
  tmux list-panes -a -F '#{pane_tty} #{pane_id}' 2>/dev/null | awk -v t="$1" '$1==t{print $2; exit}'
}

bus_alive() { kill -0 "$1" 2>/dev/null; }

# --- Claude session-file lookups (the live source of truth for name + sessionId) ---
# NB: `|| true` so a missing/unreadable session file yields empty (never a non-zero exit that would
# abort a caller running under `set -e`, e.g. `from="$(bus_name_of_pid …)"`).
bus_name_of_pid()      { jq -r '.name // empty'      "$BUS_CC_SESSIONS/$1.json" 2>/dev/null || true; }
bus_sessionid_of_pid() { jq -r '.sessionId // empty' "$BUS_CC_SESSIONS/$1.json" 2>/dev/null || true; }

# Is $1 a sessionId (UUID) rather than a human name?  (36-ish chars, only hex + hyphen)
bus_is_uuid() {
  local s="$1"
  [ ${#s} -ge 32 ] && [ -z "${s//[0-9a-fA-F-]/}" ] && case "$s" in *-*-*-*-*) return 0 ;; esac
  return 1
}

# This session's own sessionId: via its claude pid's Claude session file, else its registry entry.
bus_self_sid() {
  local pid sid f
  pid="$(bus_find_claude_pid "${1:-$$}" || true)"; [ -n "$pid" ] || return 1
  sid="$(bus_sessionid_of_pid "$pid")"; [ -n "$sid" ] && { echo "$sid"; return 0; }
  for f in "$BUS_REG"/*.json; do
    [ -e "$f" ] || continue
    [ "$(jq -r '.pid' "$f" 2>/dev/null)" = "$pid" ] && { jq -r '.sessionId' "$f"; return 0; }
  done
  return 1
}

# Latest custom-title (the current name) from a session's transcript, keyed by sessionId. Empty if
# none. Captures both local /rename and web-UI renames. Only genuine records count: `fromjson?`
# parses each candidate line and `select(.type=="custom-title")` ignores prose that merely mentions
# the string (and skips any truncated tail line). Reads the tail first (renames are recent) for
# speed, falling back to the whole file only if the tail has no title.
_bus_titles() {   # stdin: transcript lines -> stdout: custom-title values, in order
  grep -a '"type":"custom-title"' | jq -Rrc 'fromjson? | select(.type=="custom-title") | .customTitle' 2>/dev/null
}
bus_title_of_sid() {
  local sid="$1" g t
  [ -n "$sid" ] || return 0
  for g in "$BUS_CC_PROJECTS"/*/"$sid.jsonl"; do
    [ -e "$g" ] || continue
    t="$(tail -c 262144 "$g" 2>/dev/null | _bus_titles | tail -1 || true)"
    [ -n "$t" ] || t="$(_bus_titles < "$g" 2>/dev/null | tail -1 || true)"
    printf '%s' "$t"
    return 0
  done
}

# Live name resolution order: transcript custom-title > Claude session-file .name > cwd basename.
# For a registry entry file:
bus_display_name() {   # $1 = path to registry <sessionId>.json
  local sid pid cwd n=""
  sid="$(jq -r '.sessionId' "$1" 2>/dev/null || true)"
  pid="$(jq -r '.pid' "$1" 2>/dev/null || true)"
  cwd="$(jq -r '.cwd // ""' "$1" 2>/dev/null || true)"
  [ -n "$sid" ] && n="$(bus_title_of_sid "$sid")"
  [ -n "$n" ] || n="$(bus_name_of_pid "$pid")"
  [ -n "$n" ] || { [ -n "$cwd" ] && n="$(basename "$cwd")"; }
  [ -n "$n" ] || n="$sid"
  printf '%s\n' "$n"
}

# This session's own live name (same resolution order).
bus_self_name() {
  local pid sid n=""
  pid="$(bus_find_claude_pid "$$" || true)"
  sid="$(bus_self_sid || true)"
  [ -n "$sid" ] && n="$(bus_title_of_sid "$sid")"
  [ -n "$n" ] || n="$(bus_name_of_pid "$pid")"
  [ -n "$n" ] || n="$(basename "$(pwd)")"
  printf '%s\n' "$n"
}
