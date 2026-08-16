#!/usr/bin/env bash
# Zero-dependency test suite for Clatter (needs only bash + jq). Run: ./test/run.sh
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

export CLATTER_ROOT="$(mktemp -d)"
export CLATTER_SESSIONS_DIR="$(mktemp -d)"
export CLATTER_PROJECTS_DIR="$(mktemp -d)"; mkdir -p "$CLATTER_PROJECTS_DIR/p"
PIDS=()
trap 'for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$CLATTER_ROOT" "$CLATTER_SESSIONS_DIR" "$CLATTER_PROJECTS_DIR"' EXIT
titlerec(){ jq -nc --arg t "$1" --arg s "$2" '{type:"custom-title",customTitle:$t,sessionId:$s}'; }
# mksess <sessionId> <name> <cwd> [--no-transcript] -> pid. Session file gets .name="SF-<name>" so
# tests prove the transcript title wins; transcript gets custom-title=<name> unless --no-transcript.
mksess(){ sleep 600 >/dev/null 2>&1 & local p=$!; PIDS+=("$p")
  jq -n --argjson pid "$p" --arg n "SF-$2" --arg s "$1" --arg c "$3" \
    '{pid:$pid,name:$n,sessionId:$s,cwd:$c,status:"idle"}' > "$CLATTER_SESSIONS_DIR/$p.json"
  [ "${4:-}" = "--no-transcript" ] || titlerec "$2" "$1" > "$CLATTER_PROJECTS_DIR/p/$1.jsonl"
  echo "$p"; }
shopt -s nullglob

echo "Clatter test suite (root: $CLATTER_ROOT)"
A="aaaaaaaa-1111-1111-1111-111111111111"; B="bbbbbbbb-2222-2222-2222-222222222222"
C="cccccccc-3333-3333-3333-333333333333"
pa=$(mksess "$A" "alpha" "/x/alpha"); pb=$(mksess "$B" "beta" "/x/beta")
pc=$(mksess "$C" "gamma" "/x/gamma" --no-transcript)   # no transcript -> falls back to session file

"$R/bus-register.sh" --pid "$pa" --mode auto   >/dev/null
"$R/bus-register.sh" --pid "$pb" --mode manual >/dev/null
"$R/bus-register.sh" --pid "$pc" --mode auto   >/dev/null
eq "register: keyed by sessionId"   "$([ -f "$CLATTER_ROOT/registry/$A.json" ] && echo y)" y
eq "register: no name stored"       "$(jq 'has("name")' "$CLATTER_ROOT/registry/$A.json")" false
eq "register: mode persisted"       "$(jq -r .mode "$CLATTER_ROOT/registry/$B.json")" manual

peers="$("$R/bus-peers.sh")"
has "name from transcript title"    "$peers" alpha
hasnt "session-file name NOT used when transcript exists" "$peers" SF-alpha
has "fallback to session-file name" "$peers" SF-gamma
eq  "peers --json alive"            "$("$R/bus-peers.sh" --json | jq -rs 'map(select(.name=="alpha"))[0].alive')" true
eq  "resolve alpha -> A"            "$("$R/bus-resolve.sh" alpha)" "$A"
eq  "resolve unknown -> empty"      "$("$R/bus-resolve.sh" nobody)" ""

# send by name + recv + body safety
mk="$CLATTER_ROOT/PWN"
# --from-session gives a repliable sender (this test shell isn't a registered session)
"$R/bus-send.sh" alpha query "hi" 'x; touch '"$mk"' $(touch '"$mk"'2) `touch '"$mk"'3`' --from tester --from-session "$B" >/dev/null
eq  "send: delivered to A's mailbox" "$(n_json "$CLATTER_ROOT/mailbox/$A")" 1
eq  "send: to_session=A"             "$(jq -r .to_session "$CLATTER_ROOT"/mailbox/$A/*.json)" "$A"
eq  "safety: body executed nothing"  "$(set -- "$mk"*; printf '%s\n' "$#")" 0
rout="$("$R/bus-recv.sh" "$A")"
has "recv: renders body"             "$rout" "x; touch"
has "recv: reply-to is sessionId@machine" "$rout" "reply to: $B@$MACH"
# P5: a query with no repliable sender is refused
"$R/bus-send.sh" "$A" query s b --from x >/dev/null 2>&1; eq "query w/o repliable sender refused" "$?" 1

# reply path: address by sessionId directly
"$R/bus-send.sh" "$B" response "re" "answer" --reply-to "1-a" --from x >/dev/null
eq  "send: sessionId target delivers" "$(n_json "$CLATTER_ROOT/mailbox/$B")" 1

# LIVE RENAME via a new custom-title (exactly what a local /rename or web rename appends)
titlerec "alpha2" "$A" >> "$CLATTER_PROJECTS_DIR/p/$A.jsonl"
peers2="$("$R/bus-peers.sh")"
has "rename: peers shows new title"  "$peers2" alpha2
eq  "rename: new name resolves -> A" "$("$R/bus-resolve.sh" alpha2)" "$A"
eq  "rename: old name stops resolving" "$("$R/bus-resolve.sh" alpha)" ""

# --- fail-open manual-patterns guard + clat doctor ---
. "$R/_bus_common.sh"
printf '*emr*\n*legal*\n' > "$CLATTER_ROOT/manual-patterns"
eq "guard: category globs MISS a real dir (the fail-open bug)" "$(bus_manual_pattern_match /home/x/workspace/acme && echo y || echo n)" n
printf '*acme*\n' > "$CLATTER_ROOT/manual-patterns"
eq "guard: a real-name glob COVERS the dir"                    "$(bus_manual_pattern_match /home/x/workspace/acme && echo y || echo n)" y
eq "doctor: orphaned guard detected"        "$(bus_manual_patterns_orphaned && echo y || echo n)" y
"$R/bus-doctor.sh" >/dev/null 2>&1; eq "doctor: orphaned guard exits 1" "$?" 1
has "peers: warns on an orphaned guard"     "$("$R/bus-peers.sh")" "protect nothing"
pk=$(mksess "ffffffff-1111-1111-1111-111111111111" "acmesess" "/home/x/workspace/acme")
"$R/bus-register.sh" --pid "$pk" --cwd /home/x/workspace/acme --mode manual >/dev/null
eq "doctor: covered guard not orphaned"     "$(bus_manual_patterns_orphaned && echo y || echo n)" n
"$R/bus-doctor.sh" >/dev/null 2>&1; eq "doctor: covered guard exits 0" "$?" 0
rm -f "$CLATTER_ROOT/manual-patterns"

# --- duplicate live names get -2 in display + addressing (delivery still keyed by sessionId) ---
D1="dddddddd-1111-1111-1111-111111111111"; D2="dddddddd-2222-2222-2222-222222222222"
pd1=$(mksess "$D1" "dup" "/x/dup"); pd2=$(mksess "$D2" "dup" "/x/dup2")
"$R/bus-register.sh" --pid "$pd1" --mode auto >/dev/null
"$R/bus-register.sh" --pid "$pd2" --mode auto >/dev/null
dpeers="$("$R/bus-peers.sh")"
has "dup: a -2 suffix appears for the collision" "$dpeers" "dup-2"
r1="$("$R/bus-resolve.sh" dup)"; r2="$("$R/bus-resolve.sh" dup-2)"
inset(){ case " $D1 $D2 " in *" $1 "*) return 0 ;; esac; return 1; }
eq "dup: 'dup' and 'dup-2' resolve to the two distinct sessions" "$([ "$r1" != "$r2" ] && inset "$r1" && inset "$r2" && echo ok)" ok

# --- rename-into-collision notifies the mover (bus-namecheck), start-collisions do not ---
G1="99999999-1111-1111-1111-111111111111"; G2="99999999-2222-2222-2222-222222222222"
pg1=$(mksess "$G1" "foo" "/x/foo"); pg2=$(mksess "$G2" "bar" "/x/bar")
"$R/bus-register.sh" --pid "$pg1" --mode auto >/dev/null
"$R/bus-register.sh" --pid "$pg2" --mode auto >/dev/null
"$R/bus-namecheck.sh"                                    # baseline snapshot: foo, bar (distinct)
eq "namecheck: no false notify at baseline"      "$(n_json "$CLATTER_ROOT/mailbox/$G2")" 0
titlerec "foo" "$G2" >> "$CLATTER_PROJECTS_DIR/p/$G2.jsonl"   # bar -> foo : a rename into a collision
"$R/bus-namecheck.sh"
eq "namecheck: the renamer is notified"          "$(n_json "$CLATTER_ROOT/mailbox/$G2")" 1
eq "namecheck: the earlier holder is NOT"        "$(n_json "$CLATTER_ROOT/mailbox/$G1")" 0
has "namecheck: notice says name collision"      "$(jq -r '.subject' "$CLATTER_ROOT"/mailbox/$G2/*.json)" "name collision"
"$R/bus-namecheck.sh"                                    # idempotent — no second notice
eq "namecheck: not re-notified on the next run"  "$(n_json "$CLATTER_ROOT/mailbox/$G2")" 1
"$R/bus-recv.sh" "$G2" >/dev/null                        # drain so it doesn't skew later counts

# --- clear inbox: archive pending without reading ---
CS="abcdef00-1111-2222-3333-444444444444"
"$R/bus-send.sh" "$CS" notify n1 b1 --from x >/dev/null
"$R/bus-send.sh" "$CS" notify n2 b2 --from x >/dev/null
eq "clear: two messages pending"    "$(n_json "$CLATTER_ROOT/mailbox/$CS")" 2
"$R/bus-clear.sh" "$CS" >/dev/null
eq "clear: inbox emptied"           "$(n_json "$CLATTER_ROOT/mailbox/$CS")" 0
eq "clear: archived, not deleted"   "$(set -- "$CLATTER_ROOT/mailbox/$CS/archive"/*.json; printf '%s' "$#")" 2

# --- /clat mode: flip a session's mode in the registry (live) ---
"$R/bus-mode.sh" manual "$C" >/dev/null
eq "mode: flipped to manual"       "$(jq -r .mode "$CLATTER_ROOT/registry/$C.json")" manual
"$R/bus-mode.sh" auto "$C" >/dev/null
eq "mode: flipped back to auto"    "$(jq -r .mode "$CLATTER_ROOT/registry/$C.json")" auto
"$R/bus-mode.sh" bogus "$C" >/dev/null 2>&1; eq "mode: rejects invalid value" "$?" 1

# --- /clat desc: set / show in peers / clear ---
"$R/bus-desc.sh" --sid "$C" working on the relay >/dev/null
eq  "desc: stored on the entry"    "$(jq -r '.desc' "$CLATTER_ROOT/registry/$C.json")" "working on the relay"
has "desc: shown in /clat peers"     "$("$R/bus-peers.sh")" "working on the relay"
"$R/bus-desc.sh" --sid "$C" --clear >/dev/null
eq  "desc: cleared"                "$(jq -r '.desc' "$CLATTER_ROOT/registry/$C.json")" ""

# --- bus_classify_mode (shared by the SessionStart hook and the self-heal path) ---
printf '*acme*\n' > "$CLATTER_ROOT/manual-patterns"
eq "classify: manual-pattern -> manual" "$(bus_classify_mode /home/x/workspace/acme 999999)" manual
rm -f "$CLATTER_ROOT/manual-patterns"
eq "classify: no tmux pane -> manual"   "$(bus_classify_mode /home/x/plain 999999)" manual

# --- SessionEnd must NOT orphan a still-live sibling (two processes share one sessionId) ---
DUPS="deadbeef-1111-1111-1111-111111111111"
sleep 600 >/dev/null 2>&1 & qa=$!; PIDS+=("$qa")
sleep 600 >/dev/null 2>&1 & qb=$!; PIDS+=("$qb")
for p in "$qa" "$qb"; do
  jq -n --argjson pid "$p" --arg s "$DUPS" --arg c /x/dupe '{pid:$pid,name:"SF-dupe",sessionId:$s,cwd:$c,status:"idle"}' > "$CLATTER_SESSIONS_DIR/$p.json"
done
"$R/bus-register.sh" --pid "$qa" --mode auto >/dev/null
eq "dereg: entry present before"      "$([ -f "$CLATTER_ROOT/registry/$DUPS.json" ] && echo y)" y
kill "$qa" 2>/dev/null; wait "$qa" 2>/dev/null || true      # instance qa ends; qb still alive
bus_deregister_sid "$DUPS" "$qa"
eq "dereg: kept while a sibling is live" "$([ -f "$CLATTER_ROOT/registry/$DUPS.json" ] && echo y)" y
eq "dereg: repointed to live sibling"    "$(jq -r .pid "$CLATTER_ROOT/registry/$DUPS.json")" "$qb"
kill "$qb" 2>/dev/null; wait "$qb" 2>/dev/null || true      # last instance ends
bus_deregister_sid "$DUPS" "$qb"
eq "dereg: removed when none live"       "$([ -f "$CLATTER_ROOT/registry/$DUPS.json" ] && echo present || echo gone)" gone

# broadcast
"$R/bus-recv.sh" "$B" >/dev/null
"$R/bus-send.sh" _ broadcast "b" "hi all" --from tester >/dev/null
eq  "broadcast: reached A"          "$(n_json "$CLATTER_ROOT/mailbox/$A")" 1
eq  "broadcast: reached B"          "$(n_json "$CLATTER_ROOT/mailbox/$B")" 1

# cleanup prunes dead
kill "$pb" 2>/dev/null; "$R/bus-cleanup.sh" >/dev/null
eq  "cleanup: prunes dead"          "$([ -f "$CLATTER_ROOT/registry/$B.json" ] && echo y || echo n)" n
eq  "cleanup: keeps live"           "$([ -f "$CLATTER_ROOT/registry/$A.json" ] && echo y)" y

echo; echo "PASS=$PASS  FAIL=$FAIL"; [ "$FAIL" -eq 0 ]
