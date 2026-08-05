#!/usr/bin/env bash
# Clear an inbox WITHOUT reading it: move all pending messages to archive/ (reversible, not deleted).
# With no arg, clears THIS session's inbox (resolved from its claude pid); pass a sessionId to target
# a specific mailbox.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

sid="${1:-}"
[ -z "$sid" ] && sid="$(bus_self_sid || true)"
[ -z "$sid" ] && { echo "this session is not registered on the bus"; exit 0; }
case "$sid" in *[!A-Za-z0-9_-]*) echo "bus-clear: invalid sessionId '$sid'" >&2; exit 1 ;; esac

d="$BUS_MBX/$sid"; mkdir -p "$d/archive"
shopt -s nullglob
n=0
for f in "$d"/*.json; do
  mv "$f" "$d/archive/" && n=$((n + 1))
done
echo "cleared $n message(s) from the inbox (moved to archive/, not deleted)"
