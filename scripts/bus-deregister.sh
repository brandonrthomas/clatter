#!/usr/bin/env bash
# Remove this session's manifest. Called by a SessionEnd hook, or by hand.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_bus_common.sh"

self="${1:-${BUS_SELF:-}}"
[ -z "$self" ] && { echo "usage: bus-deregister.sh <self>" >&2; exit 1; }
rm -f "$BUS_REG/$self.json"
echo "deregistered '$self'"
