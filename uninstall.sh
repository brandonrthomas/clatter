#!/usr/bin/env bash
# Clatter uninstaller — reverses install.sh. Leaves your settings.json backups in place.
set -uo pipefail

DEST="${CLATTER_ROOT:-$HOME/.claude/clatter}"
CMDS="$HOME/.claude/commands"
UNITS="$HOME/.config/systemd/user"
SETTINGS="$HOME/.claude/settings.json"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1   # also delete registry/mailbox/manual-patterns

say() { printf '  %s\n' "$*"; }
echo "Clatter uninstaller"

systemctl --user disable --now clatter-relay.service 2>/dev/null || true
systemctl --user disable --now clatter-cleanup.timer 2>/dev/null || true
rm -f "$UNITS/clatter-relay.service" "$UNITS/clatter-cleanup.service" "$UNITS/clatter-cleanup.timer"
systemctl --user daemon-reload
say "services stopped + removed"

rm -f "$CMDS/clat.md"
say "removed /clat command"

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
  REG="bash $DEST/scripts/bus-hook-register.sh"
  DEREG="bash $DEST/scripts/bus-hook-deregister.sh"
  # Remove ONLY Clatter's hook entries; leave any other hooks intact; prune emptied arrays.
  jq --arg reg "$REG" --arg dereg "$DEREG" '
    def drop($ev; $c): .hooks[$ev] = ((.hooks[$ev] // []) | map(select(.hooks | map(.command) | index($c) | not)));
    drop("SessionStart"; $reg) | drop("SessionEnd"; $dereg)
    | (if (.hooks.SessionStart // []) == [] then del(.hooks.SessionStart) else . end)
    | (if (.hooks.SessionEnd   // []) == [] then del(.hooks.SessionEnd)   else . end)
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  say "removed Clatter hooks (backup saved)"
fi

if [ "$PURGE" = "1" ]; then
  rm -rf "$DEST"; say "purged $DEST (registry, mailbox, code)"
else
  rm -rf "$DEST/scripts" "$DEST/relay"
  say "removed code from $DEST (kept registry/mailbox/manual-patterns; use --purge to delete all)"
fi
echo "Done."
