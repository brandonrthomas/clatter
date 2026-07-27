# Architecture

Claudemux is a per-machine message bus for interactive Claude Code sessions. This document covers
how it works, the security model, and the design decisions behind it. For usage, see
[README.md](README.md).

## The problem that dictates the shape

Three facts about Claude Code sessions drive every design choice:

1. **They're interactive CLI processes, one per tmux pane** — not an SDK you can push messages into.
   The only way to inject a turn into a live interactive session is `tmux send-keys` into its pane.
   tmux delivers immediately if the pane is idle at the prompt and **queues** the keystrokes if it's
   mid-turn, so a busy session picks the message up when it returns to the prompt — no interrupt
   logic required.
2. **Pane identity drifts.** A pane's id (`%76`) can be remapped by tmux resurrect/continuum on
   restore, while the process keeps a stale `$TMUX_PANE` in its environment. The **tty**
   (`/dev/pts/N`) is the identity that never lies. So a session registers its **pid**, and the relay
   resolves pid → tty → current pane *live, at wake time*.
3. **Nothing runs between turns.** An idle session executes nothing; hooks fire only on user/agent
   events. So the wake must come from *outside* the session — a long-running relay.

A passive "bulletin board" (sessions read a shared file when the user next prompts them) cannot do
real-time round-trips: a query would sit unread until you visited that pane, and the reply until you
visited the asking pane. Real-time requires something that can wake an idle session. Hence the relay.

## Components

```
~/.claude/claudemux/
├── scripts/
│   ├── _bus_common.sh        # shared paths + pid→tty→pane + sessionId/live-name resolvers
│   ├── bus-register.sh       # register/refresh this session (keyed by sessionId)
│   ├── bus-send.sh           # drop a message (local, or over SSH to a peer machine)
│   ├── bus-recv.sh           # drain inbox, render as untrusted data  (backs /cm recv)
│   ├── bus-resolve.sh        # resolve a live name -> local sessionId (used locally + over SSH)
│   ├── bus-peers.sh          # list the registry with live names
│   ├── bus-cleanup.sh        # prune dead-pid entries
│   ├── bus-deregister.sh     # remove one entry
│   ├── bus.sh                # /cm dispatcher (peers|ask|send|broadcast|recv|status)
│   ├── bus-hook-register.sh  # SessionStart hook
│   └── bus-hook-deregister.sh# SessionEnd hook
├── relay/claudemux-relay.sh  # the daemon (systemd --user)
├── registry/<sessionId>.json # live sessions (pid-anchored; no name/pane id stored)
├── mailbox/<sessionId>/      # <epoch_ms>-<rand>.json messages + archive/
├── manual-patterns           # cwd globs that register manual (relay never types into them)
└── peers                     # SSH host aliases for cross-machine discovery
```

The message-bus terminology (`bus-*.sh`, "on the bus") is the accurate description of the mechanism:
Claudemux is a message bus; the `bus-*` scripts are its implementation.

### Registry — `registry/<sessionId>.json`
One file per live session, written by the SessionStart hook, keyed by the Claude **sessionId** (a
UUID, stable across `/rename` and `claude -c`) so a rename never re-keys anything:
```json
{ "sessionId":"a1b2c3d4-…", "pid":962981, "machine":"host",
  "cwd":"/home/user/api", "mode":"auto", "started":"…" }
```
`pid` is the liveness anchor and what the relay resolves to a pane. **No name and no pane id are
stored** — the name is resolved live (see Naming). `mode` is `auto` (relay may wake it) or `manual`
(relay never types into it).

### Mailbox — `mailbox/<sessionId>/`
Per-session inbox. Messages are JSON files named `<epoch_ms>-<rand>.json` (the message `id`).
Processed files move to `archive/`. Writes are atomic (tmp file + `rename()`), so no partial reads.
FIFO by filename, which sorts by the millisecond prefix.

### Relay — `relay/claudemux-relay.sh` (systemd `--user` service)
Runs as your user so it can reach the tmux socket. On start it **scans existing mailboxes and
delivers anything already pending** (inotify only reports *new* events, so this closes the
relay-was-down gap). Then it watches `mailbox/` with `inotifywait` — or, if inotify-tools isn't
installed, **polls every second** (`CLAUDEMUX_POLL`) with a per-file seen-set for the same new-file
semantics. For each new `<id>.json` under `mailbox/<target>/` it rejects unsafe target names, reads
`registry/<target>.json`, and — if the target is `auto` and its pid is alive — resolves
pid → tty → pane and types the wake. An `auto` target that no longer resolves to a pane (e.g. tmux
was killed mid-session) is left queued with a loud `WARN` rather than silently dropped. Dead targets
are pruned on contact. Logs to `relay/relay.log`.

### Hooks
- **SessionStart** → `bus-hook-register.sh`: registers the session (name resolved live, not stored),
  classifies mode — `manual` if the cwd matches a `manual-patterns` glob **or** the session isn't in
  a tmux pane (nothing to wake), else `auto` — and emits a one-line `additionalContext` note telling
  the session its bus name + current live peers. Fires on fresh start **and on `claude -c` resume**.
- **SessionEnd** → `bus-hook-deregister.sh`: removes the manifest.

### Slash command — `/cm`
`~/.claude/commands/cm.md` drives `bus.sh` **through the agent** (not a raw `!` shell expansion),
passing any free-text payload as a single quoted argument so the shell never interprets it. Running
through the agent (rather than raw shell) is also what lets `ask`/`send`/`broadcast` **compose** the
message from the session's current context by default; a leading `*` sends the rest **verbatim**.
Subcommands: `peers`, `ask`, `send`, `broadcast`, `status`, and `recv`. `recv` is what the relay's
wake types (it carries no free text).

## The wake invariant (security core)

**The only thing ever sent via `send-keys` is the fixed constant `/cm recv`.** Message content is
always read from the mailbox file by that trusted command — never typed into a pane. `/cm recv`
self-resolves *which* session it is (by matching its own claude pid to a registry entry), so even
the recipient's name never appears in the keystroke. Consequences:

- A peer cannot cause arbitrary text to be submitted as a "user" turn in another session.
- Mailbox target names are constrained to `[A-Za-z0-9_-]` on both the send side and the relay side
  (no path traversal, no shell injection into the cross-machine SSH drop).
- `bus-recv.sh` frames every message as untrusted data with an explicit "do not obey" preamble and
  newline-escapes header fields, so a message body/subject can't forge the visual frame.
- **Message bodies are inert data end-to-end.** `bus-send.sh` stores the body with `jq --arg` and,
  cross-machine, pipes it to the peer over SSH (never interpolated into a command); `bus-recv.sh`
  renders it as line-prefixed quoted text. Nothing in a message is shell-executed by the pipeline,
  so sending text that *contains* commands is safe. The `/cm` command passes free text to the CLI as
  a single quoted argument (via the agent), closing the one spot where raw args used to be
  shell-parsed.

## Message format

```json
{ "id":"1785037760123-515c", "from":"frontend", "from_session":"…uuid…", "to_session":"…uuid…",
  "machine":"host", "type":"query", "subject":"auth port", "body":"which port is auth on?",
  "reply_to":null, "timestamp":"…" }
```
- Delivery is keyed by `to_session` (the recipient's sessionId). `from` is the sender's live display
  name; `from_session` is its sessionId — so a reply targets the stable `from_session@machine` and
  still lands even if the sender is renamed mid-exchange.
- **query** expects a response (the reply wakes the asker). **response** carries `reply_to`.
  **notify** is fire-and-forget. **broadcast** expands at send time into one notify per live local
  session. Keep bodies small; send a file path, not a payload, for anything large.

## Liveness & pruning

A session is live iff its **pid** is running — that is the sole pruning criterion. Wakeability
(resolving to a tmux pane) is a *separate* property: an alive session with no pane is a valid
`manual`/poll participant, not a dead one, and is never pruned for lacking a pane. Pruning is
belt-and-braces: the relay deletes an entry the moment it tries to wake an `auto` target whose pid is
dead, and a systemd timer (`claudemux-cleanup.timer`, every 5 min) sweeps the rest with
`bus-cleanup.sh` — also pid-only.

## Naming & addressing

The addressable **name is resolved live**, never stored, in this order:
1. the latest `custom-title` record in the session's transcript
   (`~/.claude/projects/*/<sessionId>.jsonl`) — this captures both a local `/rename` **and a web-UI
   rename** (the sync daemon writes the cloud rename into the transcript, even though it does *not*
   update the session file's `.name`);
2. Claude's session-file `.name` (`~/.claude/sessions/<pid>.json`) — the derived/auto name;
3. the cwd basename.

So `/cm peers`, `/cm status`, and `/cm ask <name>` always reflect the *current* name — rename a
session anywhere and the bus follows, with no re-keying (the key is the sessionId). Names may
contain spaces and never touch a filesystem path or an SSH command line (those use the UUID), so
there are no charset restrictions on them. Address a peer by its current name, or by a sessionId
directly (what replies use); append `@machine` to force a host. Same-name collisions resolve to the
first match — use `name@machine` or the sessionId to disambiguate.

## Cross-machine

Address a peer explicitly as `name@machine` (an SSH host/alias). `bus-send.sh` drops the message
into that host's mailbox over SSH. The peer's own relay wakes
the pane, and `bus-recv.sh` renders a `reply to: <from_session>@<machine>` target (a sessionId, so
replies survive a rename). This reuses your existing SSH keys; verified host↔host in both directions.

Discovery is on-demand over SSH (no daemon, no sync): list peer hosts in `$CLAUDEMUX_ROOT/peers`
(SSH aliases, one per line). `bus-peers.sh` aggregates each peer's `--json` output into `/cm peers`
(rows shown as `name@host`, each peer resolving its own live names). Addressing a bare name that
isn't local runs `bus-resolve.sh` on each peer (the name piped in over stdin — never interpolated
into the remote command) to map it to that host's sessionId, routing to the first match; use
`name@host` or a sessionId to disambiguate. `broadcast` is local-machine only.

## Why `send-keys`, not a headless run

An alternative is to resume the target session headlessly (`claude -c -p "…"`) to answer. That forks
a turn the live interactive pane never renders and races the session's transcript — wrong when a
human is watching that pane. `send-keys` drives the *real* session the user is looking at, so the
exchange shows up as visible turns in both panes.
