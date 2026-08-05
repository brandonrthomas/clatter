#!/usr/bin/env bash
# cm doctor — check the manual-mode guard. Shows which live sessions and which ~/workspace dirs the
# manual-patterns globs currently match, so a guard that silently matches nothing (fails OPEN) is
# obvious. Exits 1 if manual-patterns has active globs but matches zero live sessions.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"
shopt -s nullglob
pat_file="$BUS_ROOT/manual-patterns"

echo "== claudemux manual-mode guard =="
echo "patterns file: $pat_file"
active_globs=0
if [ -f "$pat_file" ] && grep -qE '^[[:space:]]*[^#[:space:]]' "$pat_file"; then
  while IFS= read -r p; do
    [ -z "$p" ] && continue; case "$p" in \#*) continue ;; esac
    printf '  glob: %s\n' "$p"; active_globs=$((active_globs + 1))
  done < "$pat_file"
else
  echo "  (no active globs — every tmux session registers auto / relay-wakeable)"
fi

echo
echo "live sessions:"
sess_total=0 sess_manual_by_glob=0
for f in "$BUS_REG"/*.json; do
  bus_alive "$(jq -r '.pid' "$f" 2>/dev/null)" || continue
  sess_total=$((sess_total + 1))
  cwd="$(jq -r '.cwd // ""' "$f")"; nm="$(bus_display_name "$f")"; md="$(jq -r '.mode' "$f")"
  if bus_manual_pattern_match "$cwd"; then
    printf '  manual-by-glob  %-20s %s\n' "$nm" "$cwd"; sess_manual_by_glob=$((sess_manual_by_glob + 1))
  elif [ "$md" = auto ]; then
    printf '  AUTO            %-20s %s   <- wakeable; no glob covers it\n' "$nm" "$cwd"
  else
    printf '  %-15s %-20s %s\n' "$md" "$nm" "$cwd"
  fi
done
[ "$sess_total" -eq 0 ] && echo "  (none live)"

echo
echo "workspace dirs (~/workspace/*) — would a session here register manual?"
for d in "$HOME"/workspace/*/; do
  [ -d "$d" ] || continue; dd="${d%/}"
  if bus_manual_pattern_match "$dd"; then printf '  manual  %s\n' "$dd"; else printf '  auto    %s\n' "$dd"; fi
done

echo
if [ "$active_globs" -gt 0 ] && [ "$sess_manual_by_glob" -eq 0 ]; then
  echo "⚠ WARNING: $active_globs manual glob(s) set, but they match ZERO live sessions."
  echo "  The guard is protecting nothing, and it fails OPEN silently. Fix: make the globs match your"
  echo "  ACTUAL directory names (e.g. *acme*, *zephyr*), not category words. Mode is fixed at"
  echo "  registration — restart or re-register a session after editing patterns."
  exit 1
fi
echo "ok: $sess_manual_by_glob of $sess_total live session(s) covered by a manual glob."
