#!/usr/bin/env bash
# SessionEnd hook: remove this session's manifest — but ONLY if no other LIVE instance of the same
# sessionId remains (two concurrent `claude -c` of one session share a sessionId and one registry
# entry; this hook firing for one must not orphan the still-live sibling). See bus_deregister_sid.
# If it can't be resolved, the relay's dead-pid prune / bus-cleanup.sh reaps the stale entry later.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

sid="$(bus_self_sid || true)"
[ -n "$sid" ] && bus_deregister_sid "$sid" "$(bus_find_claude_pid "$$" || true)"
exit 0
