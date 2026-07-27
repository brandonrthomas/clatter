#!/usr/bin/env bash
# Zero-dependency test suite for Claudemux (needs only bash + jq). Run: ./test/run.sh
#
# Model: sessions are keyed by their Claude sessionId (stable). The human name is resolved LIVE,
# preferring the latest `custom-title` record in the session transcript (which captures BOTH local
# /rename and web-UI renames), then the session file's .name, then the cwd basename.
# Tests use fake session files + fake transcripts + fake pids (sleep) — no tmux/ssh.
set -u
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
MACH="$(hostname -s)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$1" "$2"; }
eq(){ if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want[$3] got[$2]"; fi; }
has(){ case "$2" in *"$3"*) ok "$1";; *) no "$1" "missing[$3]";; esac; }
hasnt(){ case "$2" in *"$3"*) no "$1" "unexpected[$3]";; *) ok "$1";; esac; }
n_json(){ set -- "$1"/*.json; printf '%s\n' "$#"; }

export CLAUDEMUX_ROOT="$(mktemp -d)"
export CLAUDEMUX_SESSIONS_DIR="$(mktemp -d)"
export CLAUDEMUX_PROJECTS_DIR="$(mktemp -d)"; mkdir -p "$CLAUDEMUX_PROJECTS_DIR/p"
PIDS=()
trap 'for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$CLAUDEMUX_ROOT" "$CLAUDEMUX_SESSIONS_DIR" "$CLAUDEMUX_PROJECTS_DIR"' EXIT
titlerec(){ jq -nc --arg t "$1" --arg s "$2" '{type:"custom-title",customTitle:$t,sessionId:$s}'; }
# mksess <sessionId> <name> <cwd> [--no-transcript] -> pid. Session file gets .name="SF-<name>" so
# tests prove the transcript title wins; transcript gets custom-title=<name> unless --no-transcript.
mksess(){ sleep 600 >/dev/null 2>&1 & local p=$!; PIDS+=("$p")
  jq -n --argjson pid "$p" --arg n "SF-$2" --arg s "$1" --arg c "$3" \
    '{pid:$pid,name:$n,sessionId:$s,cwd:$c,status:"idle"}' > "$CLAUDEMUX_SESSIONS_DIR/$p.json"
  [ "${4:-}" = "--no-transcript" ] || titlerec "$2" "$1" > "$CLAUDEMUX_PROJECTS_DIR/p/$1.jsonl"
  echo "$p"; }
shopt -s nullglob

echo "Claudemux test suite (root: $CLAUDEMUX_ROOT)"
A="aaaaaaaa-1111-1111-1111-111111111111"; B="bbbbbbbb-2222-2222-2222-222222222222"
C="cccccccc-3333-3333-3333-333333333333"
pa=$(mksess "$A" "alpha" "/x/alpha"); pb=$(mksess "$B" "beta" "/x/beta")
pc=$(mksess "$C" "gamma" "/x/gamma" --no-transcript)   # no transcript -> falls back to session file

"$R/bus-register.sh" --pid "$pa" --mode auto   >/dev/null
"$R/bus-register.sh" --pid "$pb" --mode manual >/dev/null
"$R/bus-register.sh" --pid "$pc" --mode auto   >/dev/null
eq "register: keyed by sessionId"   "$([ -f "$CLAUDEMUX_ROOT/registry/$A.json" ] && echo y)" y
eq "register: no name stored"       "$(jq 'has("name")' "$CLAUDEMUX_ROOT/registry/$A.json")" false
eq "register: mode persisted"       "$(jq -r .mode "$CLAUDEMUX_ROOT/registry/$B.json")" manual

peers="$("$R/bus-peers.sh")"
has "name from transcript title"    "$peers" alpha
hasnt "session-file name NOT used when transcript exists" "$peers" SF-alpha
has "fallback to session-file name" "$peers" SF-gamma
eq  "peers --json alive"            "$("$R/bus-peers.sh" --json | jq -rs 'map(select(.name=="alpha"))[0].alive')" true
eq  "resolve alpha -> A"            "$("$R/bus-resolve.sh" alpha)" "$A"
eq  "resolve unknown -> empty"      "$("$R/bus-resolve.sh" nobody)" ""

# send by name + recv + body safety
mk="$CLAUDEMUX_ROOT/PWN"
# --from-session gives a repliable sender (this test shell isn't a registered session)
"$R/bus-send.sh" alpha query "hi" 'x; touch '"$mk"' $(touch '"$mk"'2) `touch '"$mk"'3`' --from tester --from-session "$B" >/dev/null
eq  "send: delivered to A's mailbox" "$(n_json "$CLAUDEMUX_ROOT/mailbox/$A")" 1
eq  "send: to_session=A"             "$(jq -r .to_session "$CLAUDEMUX_ROOT"/mailbox/$A/*.json)" "$A"
eq  "safety: body executed nothing"  "$(set -- "$mk"*; printf '%s\n' "$#")" 0
rout="$("$R/bus-recv.sh" "$A")"
has "recv: renders body"             "$rout" "x; touch"
has "recv: reply-to is sessionId@machine" "$rout" "reply to: $B@$MACH"
# P5: a query with no repliable sender is refused
"$R/bus-send.sh" "$A" query s b --from x >/dev/null 2>&1; eq "query w/o repliable sender refused" "$?" 1

# reply path: address by sessionId directly
"$R/bus-send.sh" "$B" response "re" "answer" --reply-to "1-a" --from x >/dev/null
eq  "send: sessionId target delivers" "$(n_json "$CLAUDEMUX_ROOT/mailbox/$B")" 1

# LIVE RENAME via a new custom-title (exactly what a local /rename or web rename appends)
titlerec "alpha2" "$A" >> "$CLAUDEMUX_PROJECTS_DIR/p/$A.jsonl"
peers2="$("$R/bus-peers.sh")"
has "rename: peers shows new title"  "$peers2" alpha2
eq  "rename: new name resolves -> A" "$("$R/bus-resolve.sh" alpha2)" "$A"
eq  "rename: old name stops resolving" "$("$R/bus-resolve.sh" alpha)" ""

# broadcast
"$R/bus-recv.sh" "$B" >/dev/null
"$R/bus-send.sh" _ broadcast "b" "hi all" --from tester >/dev/null
eq  "broadcast: reached A"          "$(n_json "$CLAUDEMUX_ROOT/mailbox/$A")" 1
eq  "broadcast: reached B"          "$(n_json "$CLAUDEMUX_ROOT/mailbox/$B")" 1

# cleanup prunes dead
kill "$pb" 2>/dev/null; "$R/bus-cleanup.sh" >/dev/null
eq  "cleanup: prunes dead"          "$([ -f "$CLAUDEMUX_ROOT/registry/$B.json" ] && echo y || echo n)" n
eq  "cleanup: keeps live"           "$([ -f "$CLAUDEMUX_ROOT/registry/$A.json" ] && echo y)" y

echo; echo "PASS=$PASS  FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
