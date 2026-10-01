#!/usr/bin/env bash
# Clatter relay: watch all mailboxes; on a new message for session X, wake X's tmux
# pane so it drains its inbox. Runs as a per-machine systemd --user service (as the invoking
# user, so it can reach the tmux socket). The ONLY text ever typed into a pane is a fixed control
# line — never message content — and Enter is sent only after the pane is verified to be at an
# empty input box (never on a dialog, never on someone's half-typed draft); otherwise the wake is
# deferred and retried.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../scripts/_bus_common.sh"
LOG="${CLATTER_RELAY_LOG:-$DIR/relay.log}"

mkdir -p "$BUS_MBX"
log() { echo "$(date -Is) $*" >> "$LOG"; }
log "relay starting; watching $BUS_MBX"

# Periodic name-collision check: notifies a session that /rename'd onto a name already in use. It
# drops a notice into that session's mailbox, which this relay then delivers via the normal wake.
# Set CLATTER_NAMECHECK_INTERVAL=0 to disable. Runs in the background; dies with the relay (cgroup).
NAMECHECK_INT="${CLATTER_NAMECHECK_INTERVAL:-10}"
if [ "$NAMECHECK_INT" -gt 0 ] 2>/dev/null; then
  ( while sleep "$NAMECHECK_INT"; do "$DIR/../scripts/bus-namecheck.sh" >>"$LOG" 2>&1 || true; done ) &
  log "namecheck heartbeat every ${NAMECHECK_INT}s (pid $!)"
fi

# Deferred wakes: a target whose pane wasn't safely at an empty prompt gets a marker file here, and
# the retry loop below re-attempts it — so its message is delivered as soon as the pane is ready.
DEFER_DIR="$BUS_ROOT/.deferred"; mkdir -p "$DEFER_DIR"
defer()      { [ -e "$DEFER_DIR/$1" ] || log "deferred '$1': $2 — message stays queued; retrying"; : > "$DEFER_DIR/$1"; }
undefer()    { rm -f "$DEFER_DIR/$1"; }
pane_input() { tmux capture-pane -p -t "$1" 2>/dev/null | bus_screen_input_line; }

# One wake at a time (the event loop and the retry loop can race). Blocking, so a wake is never
# skipped — a skipped one could miss a message that landed just after the other attempt looked.
wake() { ( flock 9; wake_locked "$1" ) 9>"$DEFER_DIR/.wake.lock"; }

wake_locked() {
  local target="$1" reg="$BUS_REG/$1.json" mode pid tty pane line i
  [ -f "$reg" ] || { log "no registry for '$target'; skip"; undefer "$target"; return; }
  mode=$(jq -r '.mode' "$reg"); pid=$(jq -r '.pid' "$reg")
  [ "$mode" = "auto" ] || { log "'$target' mode=$mode; not waking"; undefer "$target"; return; }
  bus_alive "$pid" || { log "'$target' pid $pid dead; pruning entry"; rm -f "$reg"; undefer "$target"; return; }
  # Reaching here means mode=auto, so the session was classified wakeable at registration. If we now
  # can't find a pane, that's an anomaly (tmux died mid-session) — the message stays queued and we say
  # so loudly, rather than silently dropping the wake.
  tty=$(bus_pid_to_tty "$pid" || true)
  [ -n "$tty" ] || { log "WARN '$target' is mode=auto but pid $pid has no tty — cannot wake; message queued"; undefer "$target"; return; }
  pane=$(bus_tty_to_pane "$tty")
  [ -n "$pane" ] || { log "WARN '$target' is mode=auto but tty $tty maps to no tmux pane — cannot wake; message queued (tmux gone?)"; undefer "$target"; return; }
  # Nothing left to deliver (e.g. the user already ran /clat recv) -> nothing to do.
  set -- "$BUS_MBX/$target"/*.json; [ -e "$1" ] || { undefer "$target"; return; }

  # HARD INVARIANT: the ONLY text ever typed into a pane is the fixed constant `/clat recv` — never a
  # name, path, or any sender-influenced data; /clat recv self-resolves its session and reads the
  # mailbox itself. And Enter is pressed only after the screen proves where it will land, because an
  # Enter on a permission prompt approves it and on /model sets the default model (both verified live).
  # 1) Type only into an EMPTY input box: no dialog up and no half-typed draft. (Exactly `/clat recv`
  #    already there is our own text from an attempt whose repaint was slow — just submit it.)
  line=$(pane_input "$pane") || { defer "$target" "no input box on screen (a dialog or prompt is up)"; return; }
  if [ "$line" != "/clat recv" ]; then
    [ -z "$line" ] || { defer "$target" "input line is not empty (someone is typing)"; return; }
    tmux send-keys -t "$pane" -l '/clat recv'
  fi
  # 2) Press Enter only once the input line reads back exactly what we typed.
  for i in $(seq 1 20); do
    line=$(pane_input "$pane") && [ "$line" = "/clat recv" ] && break
    sleep 0.1
  done
  if [ "$line" = "/clat recv" ]; then
    tmux send-keys -t "$pane" Enter
    undefer "$target"
    log "woke '$target' (pid $pid, tty $tty, pane $pane) via /clat recv"
  else
    # The screen changed under us. If our text is still at the end of the input line, take back
    # exactly those 10 characters; otherwise send nothing more (keys could land on a dialog).
    case "$line" in
      *"/clat recv") tmux send-keys -t "$pane" BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace BSpace ;;
      *) log "WARN '$target': screen changed between typing /clat recv and Enter; sent nothing more" ;;
    esac
    defer "$target" "input line didn't read back as /clat recv"
  fi
}

# Retry deferred wakes every CLATTER_WAKE_RETRY seconds (0 disables). Background; dies with the relay.
WAKE_RETRY="${CLATTER_WAKE_RETRY:-5}"
if [ "$WAKE_RETRY" -gt 0 ] 2>/dev/null; then
  ( while sleep "$WAKE_RETRY"; do
      for m in "$DEFER_DIR"/*; do
        [ -e "$m" ] || continue
        t="$(basename "$m")"; case "$t" in ''|.*|*[!A-Za-z0-9_-]*) continue ;; esac
        wake "$t"
      done
    done ) &
  log "deferred-wake retry every ${WAKE_RETRY}s (pid $!)"
fi

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
  # Zero-dependency fallback when inotify-tools isn't installed: poll every CLATTER_POLL seconds.
  # Message filenames are unique, so a per-file seen-set gives new-file semantics with no re-wakes;
  # the first tick delivers anything already pending.
  POLL="${CLATTER_POLL:-1}"; case "$POLL" in ''|*[!0-9.]*) POLL=1 ;; esac
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
