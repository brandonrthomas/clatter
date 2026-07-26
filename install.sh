#!/usr/bin/env bash
# Claudemux installer — idempotent, safe to re-run.
# Installs to ~/.claude/claudemux, adds the /cm command + SessionStart/End hooks, and
# enables the relay + cleanup timer as systemd --user services.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${CLAUDEMUX_ROOT:-$HOME/.claude/claudemux}"
CMDS="$HOME/.claude/commands"
UNITS="$HOME/.config/systemd/user"
SETTINGS="$HOME/.claude/settings.json"

say() { printf '  %s\n' "$*"; }
echo "Claudemux installer"

# --- dependencies ---
missing=""
for c in jq tmux; do command -v "$c" >/dev/null 2>&1 || missing="$missing $c"; done
if [ -n "$missing" ]; then
  echo "Missing dependencies:$missing" >&2
  echo "Install them first, e.g.:  sudo apt install jq tmux" >&2
  exit 1
fi
command -v inotifywait >/dev/null 2>&1 || echo "  note: inotify-tools absent — the relay will poll (slightly higher latency)."
command -v systemctl >/dev/null 2>&1 || { echo "systemctl not found (this installer targets systemd --user)." >&2; exit 1; }

# --- 1) code ---
mkdir -p "$DEST/scripts" "$DEST/relay" "$DEST/mailbox" "$DEST/registry" "$CMDS" "$UNITS"
cp "$SRC"/scripts/*.sh "$DEST/scripts/"
cp "$SRC"/relay/*.sh   "$DEST/relay/"
chmod +x "$DEST"/scripts/*.sh "$DEST"/relay/*.sh
cp "$SRC"/commands/cm.md "$CMDS/"
cp "$SRC"/systemd/claudemux-*.service "$SRC"/systemd/claudemux-*.timer "$UNITS/"
[ -f "$DEST/manual-patterns" ] || cp "$SRC/manual-patterns.example" "$DEST/manual-patterns"
[ -f "$DEST/peers" ]           || cp "$SRC/peers.example"           "$DEST/peers"
say "code -> $DEST"

# --- 2) hooks (merge into settings.json, preserving everything else; back up first) ---
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
REG="bash $DEST/scripts/bus-hook-register.sh"
DEREG="bash $DEST/scripts/bus-hook-deregister.sh"
# Append our hooks WITHOUT clobbering the user's other SessionStart/End hooks; dedup on re-run.
jq --arg reg "$REG" --arg dereg "$DEREG" '
  def put($ev; $c):
    .hooks[$ev] = (((.hooks[$ev] // [])
      | map(select(.hooks | map(.command) | index($c) | not)))
      + [{"hooks":[{"type":"command","command":$c}]}]);
  put("SessionStart"; $reg) | put("SessionEnd"; $dereg)
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
say "hooks -> $SETTINGS (backup saved alongside)"

# --- 3) services ---
systemctl --user daemon-reload
systemctl --user enable --now claudemux-relay.service
systemctl --user enable --now claudemux-cleanup.timer
say "enabled claudemux-relay.service + claudemux-cleanup.timer"

echo
echo "Done. New sessions auto-register; existing ones join when you restart or 'claude -c' them."
echo "Try it:  open two Claude Code sessions, then in one run  /cm peers  and  /cm ask <other> \"hi\""
echo "Sensitive workspaces: add globs to  $DEST/manual-patterns  (see manual-patterns.example)."
