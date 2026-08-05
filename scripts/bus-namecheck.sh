#!/usr/bin/env bash
# Notify a session when a /rename lands it on a name already held by another live session.
#
# There is no rename hook in Claude Code, so we can't intercept /rename. Instead this runs
# periodically (from the relay) and compares each live session's resolved name to a saved snapshot.
# A session whose name *changed* into a collision (a deliberate rename) gets a one-time notice in
# its mailbox — which the relay then delivers via the normal wake. Start-time duplicates (two
# sessions that were always the same name) are handled by the -N display suffix + the SessionStart
# note, so they are deliberately NOT notified here (their name never changed).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

state="$BUS_ROOT/.namecheck-state"        # sid \t base   (last snapshot)
notified="$BUS_ROOT/.namecheck-notified"  # sid \t base   (already told, to avoid repeats)
mkdir -p "$BUS_ROOT"
shopt -s nullglob

notify_collision() {   # $1 = sid, $2 = colliding name
  local sid="$1" name="$2" id ts d
  id="$(date +%s%3N)-nc$RANDOM"; ts="$(date -Is)"
  d="$BUS_MBX/$sid"; mkdir -p "$d/archive"
  jq -nc --arg id "$id" --arg name "$name" --arg sid "$sid" --arg machine "$BUS_SELF_MACHINE" --arg ts "$ts" \
    '{id:$id, from:"claudemux", from_session:"claudemux", to_session:$sid, machine:$machine,
      type:"notify", subject:"name collision",
      body:("Heads up: your bus name \""+$name+"\" is already used by another live session. Two sessions sharing a name are ambiguous for peers to address, so please /rename to something unique. Until then peers see you as \""+$name+"-2\" (or -3, ...).") ,
      reply_to:null, timestamp:$ts}' > "$d/.$id.tmp" && mv "$d/.$id.tmp" "$d/$id.json"
}

# --- current live sessions: base name + started, per sid ---
declare -A cur_base
tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
for f in "$BUS_REG"/*.json; do
  pid="$(jq -r '.pid' "$f" 2>/dev/null)"; bus_alive "$pid" || continue
  sid="$(jq -r '.sessionId' "$f" 2>/dev/null)"; [ -n "$sid" ] || continue
  started="$(jq -r '.started // ""' "$f" 2>/dev/null)"
  base="$(bus_display_name "$f")"; base="${base//$'\t'/ }"; base="${base//$'\n'/ }"
  cur_base["$sid"]="$base"
  printf '%s\t%s\t%s\n' "$base" "$started" "$sid" >> "$tmp"
done

# holder of each name = earliest by (started, sid); everyone else with that name is a "loser"
declare -A holder
while IFS=$'\t' read -r base started sid; do
  [ -n "${holder[$base]:-}" ] || holder["$base"]="$sid"
done < <(sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 "$tmp")

# --- previous snapshot + already-notified ---
declare -A prev_base notified_map
[ -f "$state" ]    && while IFS=$'\t' read -r s b; do [ -n "$s" ] && prev_base["$s"]="$b"; done < "$state"
[ -f "$notified" ] && while IFS=$'\t' read -r s b; do [ -n "$s" ] && notified_map["$s"]="$b"; done < "$notified"

# --- notify losers whose name CHANGED into the collision (a rename), once per (sid,name) ---
for sid in "${!cur_base[@]}"; do
  base="${cur_base[$sid]}"
  [ "${holder[$base]:-$sid}" = "$sid" ] && continue     # holder keeps the bare name; not a loser
  prev="${prev_base[$sid]:-}"
  [ -n "$prev" ] && [ "$prev" != "$base" ] || continue  # only a *change* into a collision (rename)
  if [ "${notified_map[$sid]:-}" != "$base" ]; then
    notify_collision "$sid" "$base"
    notified_map["$sid"]="$base"
  fi
done

# --- persist: keep notified entries only while still a live loser on the same name (so a later
#     re-collision notifies again); snapshot current names ---
: > "$notified.tmp"
for sid in "${!notified_map[@]}"; do
  b="${notified_map[$sid]}"
  [ "${cur_base[$sid]:-}" = "$b" ] || continue
  [ "${holder[$b]:-$sid}" = "$sid" ] && continue
  printf '%s\t%s\n' "$sid" "$b" >> "$notified.tmp"
done
mv "$notified.tmp" "$notified"

: > "$state.tmp"
for sid in "${!cur_base[@]}"; do printf '%s\t%s\n' "$sid" "${cur_base[$sid]}" >> "$state.tmp"; done
mv "$state.tmp" "$state"
