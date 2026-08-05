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

# --- manual-mode guard helpers -------------------------------------------------------------
# Does cwd $1 match any glob in the manual-patterns file? 0 = yes. Shared by the register hook
# and `cm doctor` so they can never disagree about what the guard covers.
bus_manual_pattern_match() {
  local cwd="$1" pat_file="$BUS_ROOT/manual-patterns" pat
  [ -f "$pat_file" ] || return 1
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue; case "$pat" in \#*) continue ;; esac
    # shellcheck disable=SC2254  # glob from a trusted local config, matched against a path
    case "$cwd" in $pat) return 0 ;; esac
  done < "$pat_file"
  return 1
}

# 0 (true) if manual-patterns has at least one active glob but NONE match any live session's cwd
# — i.e. the guard is set yet protecting nothing (it fails OPEN, silently). Used to warn loudly.
bus_manual_patterns_orphaned() {
  local pat_file="$BUS_ROOT/manual-patterns" f cwd
  [ -f "$pat_file" ] || return 1
  grep -qE '^[[:space:]]*[^#[:space:]]' "$pat_file" || return 1   # any non-comment glob?
  for f in "$BUS_REG"/*.json; do
    [ -e "$f" ] || continue
    bus_alive "$(jq -r '.pid' "$f" 2>/dev/null)" || continue
    cwd="$(jq -r '.cwd // ""' "$f" 2>/dev/null)"
    bus_manual_pattern_match "$cwd" && return 1                   # something matches -> not orphaned
  done
  return 0
}

# --- name disambiguation -------------------------------------------------------------------
# Emit one line per LIVE LOCAL session:  <sid>\t<pid>\t<mode>\t<unique-name>
# When several live sessions resolve to the same name, the earliest (by started, then sessionId)
# keeps the bare name and the rest get -2/-3/... suffixes. These suffixes are display/addressing
# only — delivery is always keyed by sessionId, so a shifting suffix never misroutes a message.
bus_local_roster() {
  local f sid pid mode started base
  {
    for f in "$BUS_REG"/*.json; do
      [ -e "$f" ] || continue
      pid="$(jq -r '.pid' "$f" 2>/dev/null)"; bus_alive "$pid" || continue
      sid="$(jq -r '.sessionId' "$f" 2>/dev/null)"
      mode="$(jq -r '.mode // "auto"' "$f" 2>/dev/null)"
      started="$(jq -r '.started // ""' "$f" 2>/dev/null)"
      base="$(bus_display_name "$f")"; base="${base//$'\t'/ }"; base="${base//$'\n'/ }"
      printf '%s\t%s\t%s\t%s\t%s\n' "$started" "$sid" "$pid" "$mode" "$base"
    done
  } | sort -t"$(printf '\t')" -k1,1 -k2,2 | awk -F'\t' '
    { n = ++cnt[$5]; name = (n==1 ? $5 : $5 "-" n)
      printf "%s\t%s\t%s\t%s\n", $2, $3, $4, name }'
}

# This session's own disambiguated (unique) bus name, given its sessionId. Empty if not live.
bus_unique_name_of_sid() {
  bus_local_roster | awk -F'\t' -v s="$1" '$1==s{print $4; exit}'
}
