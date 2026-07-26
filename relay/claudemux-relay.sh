#!/usr/bin/env bash
# Claudemux relay: watch all mailboxes; on a new message for session X, wake X's tmux
# pane so it drains its inbox. Runs as a per-machine systemd --user service (as the invoking
# user, so it can reach the tmux socket). The ONLY thing ever typed into a pane is a fixed control
# line — never message content.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../scripts/_bus_common.sh"
LOG="${CLAUDEMUX_RELAY_LOG:-$DIR/relay.log}"

mkdir -p "$BUS_MBX"
log() { echo "$(date -Is) $*" >> "$LOG"; }
log "relay starting; watching $BUS_MBX"

wake() {
  local target="$1" reg="$BUS_REG/$1.json" mode pid tty pane
  [ -f "$reg" ] || { log "no registry for '$target'; skip"; return; }
  mode=$(jq -r '.mode' "$reg"); pid=$(jq -r '.pid' "$reg")
  [ "$mode" = "auto" ] || { log "'$target' mode=$mode; not waking"; return; }
  bus_alive "$pid" || { log "'$target' pid $pid dead; pruning entry"; rm -f "$reg"; return; }
  tty=$(bus_pid_to_tty "$pid" || true)
  [ -n "$tty" ] || { log "'$target' pid $pid has no tty; skip"; return; }
  pane=$(bus_tty_to_pane "$tty")
  [ -n "$pane" ] || { log "'$target' tty $tty -> no tmux pane; skip"; return; }
  # HARD INVARIANT: the ONLY thing ever typed into a pane is this fixed constant — never a
  # name, path, or any sender-influenced data. /cm recv self-resolves which session it is,
  # then reads the mailbox itself. This keeps the send-keys injection surface a single literal.
  tmux send-keys -t "$pane" -l '/cm recv'
  tmux send-keys -t "$pane" Enter
  log "woke '$target' (pid $pid, tty $tty, pane $pane) via /cm recv"
}

# Deliver anything already sitting in mailboxes on startup. inotify only reports NEW events, so a
# message that arrived while the relay was down would otherwise wait until the next event.
scan_pending() {
  shopt -s nullglob
  local d st pending
  for d in "$BUS_MBX"/*/; do
    st="$(basename "$d")"
    case "$st" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
    pending=("$d"*.json)
    [ ${#pending[@]} -gt 0 ] && { log "startup: ${#pending[@]} pending for '$st'"; wake "$st"; }
  done
}

if command -v inotifywait >/dev/null 2>&1; then
  scan_pending
  # create fires on the .tmp; moved_to fires on the final rename to <id>.json — act on .json only.
  inotifywait -m -r -e create -e moved_to --format '%w%f' "$BUS_MBX" 2>>"$LOG" | while read -r path; do
    case "$path" in
      */archive/*) continue ;;
      *.json) ;;
      *) continue ;;
    esac
    target=$(basename "$(dirname "$path")")
    case "$target" in
      ''|*[!A-Za-z0-9_-]*) log "reject unsafe target name '$target' (from $path)"; continue ;;
    esac
    log "event: $path (target '$target')"
    wake "$target"
  done
else
  # Zero-dependency fallback when inotify-tools isn't installed: poll every CLAUDEMUX_POLL seconds.
  # Message filenames are unique, so a per-file seen-set gives new-file semantics with no re-wakes;
  # the first tick delivers anything already pending.
  POLL="${CLAUDEMUX_POLL:-1}"; case "$POLL" in ''|*[!0-9.]*) POLL=1 ;; esac
  log "inotifywait not found — polling every ${POLL}s"
  declare -A seen
  while true; do
    shopt -s nullglob
    for f in "$BUS_MBX"/*/*.json; do
      case "$f" in */archive/*) continue ;; esac
      [ -n "${seen[$f]:-}" ] && continue
      seen[$f]=1
      target="$(basename "$(dirname "$f")")"
      case "$target" in ''|*[!A-Za-z0-9_-]*) continue ;; esac
      log "poll: $f (target '$target')"
      wake "$target"
    done
    sleep "$POLL"
  done
fi
