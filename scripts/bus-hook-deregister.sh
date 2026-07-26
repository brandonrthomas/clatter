#!/usr/bin/env bash
# SessionEnd hook: remove this session's manifest. If the pid is already gone and self can't be
# resolved, the relay's pid-prune / bus-cleanup.sh will reap the stale entry later.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

self="$(bus_resolve_self_name || true)"
[ -n "$self" ] && rm -f "$BUS_REG/$self.json"
exit 0
