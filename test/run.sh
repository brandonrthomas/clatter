#!/usr/bin/env bash
# Zero-dependency test suite for Claudemux. Requires only: bash, jq.
# Run:  ./test/run.sh    (exits non-zero if any test fails)
#
# Tests the pure scripts (register/send/recv/peers/cleanup) against an isolated CLAUDEMUX_ROOT with
# fake sessions (sleep pids). The relay + cross-machine SSH are integration paths, not covered here.
set -u

S="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "output lacks [$3]";; esac; }
rc()  { local d="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; eq "$d" "$?" "$want"; }
isfile() { [ -f "$1" ] && echo y || echo n; }
count()  { set -- "$@"; printf '%s\n' "$#"; }   # count glob-expanded args (0 if none via nullglob)

export CLAUDEMUX_ROOT; CLAUDEMUX_ROOT="$(mktemp -d)"
PIDS=()
trap 'for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null; done; rm -rf "$CLAUDEMUX_ROOT"' EXIT
livepid() { sleep 600 >/dev/null 2>&1 & local p=$!; PIDS+=("$p"); echo "$p"; }  # redirect fds: else $(…) blocks
shopt -s nullglob

echo "Claudemux test suite  (root: $CLAUDEMUX_ROOT)"

# ---- registration ----
p1=$(livepid)
"$S/bus-register.sh" alpha --pid "$p1" --desc "frontend" --mode auto >/dev/null
eq  "register: manifest created"      "$(isfile "$CLAUDEMUX_ROOT/registry/alpha.json")" y
eq  "register: pid persisted"         "$(jq -r .pid  "$CLAUDEMUX_ROOT/registry/alpha.json")" "$p1"
eq  "register: mode persisted"        "$(jq -r .mode "$CLAUDEMUX_ROOT/registry/alpha.json")" auto
"$S/bus-register.sh" secure --pid "$(livepid)" --mode manual >/dev/null
eq  "register: manual mode"           "$(jq -r .mode "$CLAUDEMUX_ROOT/registry/secure.json")" manual

# ---- auto-naming: basename, collision suffix, reuse-own-pid ----
proj="$CLAUDEMUX_ROOT/ws/myproj"; mkdir -p "$proj"
pa=$(livepid); pb=$(livepid)
( cd "$proj" && "$S/bus-register.sh" --pid "$pa" ) >/dev/null
( cd "$proj" && "$S/bus-register.sh" --pid "$pb" ) >/dev/null
eq  "auto-name: basename(cwd)"        "$(isfile "$CLAUDEMUX_ROOT/registry/myproj.json")"   y
eq  "auto-name: collision -> -2"      "$(isfile "$CLAUDEMUX_ROOT/registry/myproj-2.json")" y
( cd "$proj" && "$S/bus-register.sh" --pid "$pa" ) >/dev/null
eq  "auto-name: reuse own pid (no -3)" "$(isfile "$CLAUDEMUX_ROOT/registry/myproj-3.json")" n

# ---- peers / discovery --json ----
has "peers: lists a session"          "$("$S/bus-peers.sh")" alpha
eq  "peers --json: alive=true"        "$("$S/bus-peers.sh" --json | jq -r 'select(.name=="alpha").alive')" true

# ---- send + recv + body safety ----
mark="$CLAUDEMUX_ROOT/PWN"
body='hi; touch '"$mark"' $(touch '"$mark"'2) `touch '"$mark"'3`'
BUS_SELF=sender "$S/bus-send.sh" alpha notify "subj" "$body" >/dev/null
eq  "safety: nothing executed on send" "$(count "$mark"*)" 0
eq  "send: body stored verbatim"       "$(jq -r .body "$CLAUDEMUX_ROOT"/mailbox/alpha/*.json)" "$body"
out="$("$S/bus-recv.sh" alpha)"
has "recv: renders the body"           "$out" "hi; touch"
eq  "safety: nothing executed on recv" "$(count "$mark"*)" 0
eq  "recv: inbox drained"              "$(count "$CLAUDEMUX_ROOT"/mailbox/alpha/*.json)" 0
eq  "recv: message archived"           "$(count "$CLAUDEMUX_ROOT"/mailbox/alpha/archive/*.json)" 1

# ---- target validation + unknown-target guard ----
rc  "reject path-traversal target"  1 "$S/bus-send.sh" "../evil" notify s b --from x
rc  "reject spaced target"          1 "$S/bus-send.sh" "a b"     notify s b --from x
rc  "unknown target errors (P3)"    1 "$S/bus-send.sh" nobody    notify s b --from x

# ---- reply_to + reply-routing (local vs cross-machine) ----
BUS_SELF=bob "$S/bus-send.sh" alpha response "re" "answer" --reply-to "12345-abcd" >/dev/null
out="$("$S/bus-recv.sh" alpha)"
has "recv: shows reply_to"            "$out" "reply_to: 12345-abcd"
has "recv: local reply-to (no @)"     "$out" "reply to: bob"
# craft a message that "arrived" from another host (machine != local) — tests recv's reply routing
# directly, without a live SSH send
mid="$(date +%s%3N)-x"
jq -n --arg id "$mid" '{id:$id,from:"carol",to:"alpha",machine:"otherhost",type:"notify",
  subject:"x",body:"hi",reply_to:null,timestamp:"t"}' > "$CLAUDEMUX_ROOT/mailbox/alpha/$mid.json"
out="$("$S/bus-recv.sh" alpha)"
has "recv: cross-machine reply-to"    "$out" "reply to: carol@otherhost"

# ---- broadcast ----
BUS_SELF=alpha "$S/bus-send.sh" _ broadcast "all" "heads up" >/dev/null
eq  "broadcast: reached other session" "$(count "$CLAUDEMUX_ROOT"/mailbox/secure/*.json)" 1
eq  "broadcast: skipped self (alpha)"  "$(count "$CLAUDEMUX_ROOT"/mailbox/alpha/*.json)"  0

# ---- cleanup / liveness ----
pd=$(livepid); "$S/bus-register.sh" doomed --pid "$pd" >/dev/null
kill "$pd" 2>/dev/null
"$S/bus-cleanup.sh" >/dev/null
eq  "cleanup: prunes dead pid"        "$(isfile "$CLAUDEMUX_ROOT/registry/doomed.json")" n
eq  "cleanup: keeps live session"     "$(isfile "$CLAUDEMUX_ROOT/registry/alpha.json")"  y

echo
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
