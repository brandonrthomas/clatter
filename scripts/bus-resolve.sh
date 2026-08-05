#!/usr/bin/env bash
# Resolve a human session NAME to a LOCAL sessionId, using live names (first live match wins).
# Prints the sessionId, or nothing if no live local session currently has that name.
# Read the name from argv, or from stdin with --stdin (used over SSH so names are never
# interpolated into a remote command line).
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

want="${1:-}"
[ "$want" = "--stdin" ] && want="$(cat)"
[ -z "$want" ] && exit 0

# Match against the disambiguated roster so "explore" and "explore-2" each resolve to the right
# session (and a bare name maps to the earliest holder). Delivery is by the sessionId returned here.
bus_local_roster | awk -F'\t' -v w="$want" '$4==w{print $1; exit}'
exit 0
