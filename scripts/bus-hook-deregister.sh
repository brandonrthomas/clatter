#!/usr/bin/env bash
# SessionEnd hook: remove this session's manifest (by its sessionId). If it can't be resolved,
# the relay's dead-pid prune / bus-cleanup.sh reaps the stale entry later.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

sid="$(bus_self_sid || true)"
[ -n "$sid" ] && rm -f "$BUS_REG/$sid.json"
exit 0
