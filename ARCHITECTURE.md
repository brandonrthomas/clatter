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
│   ├── _bus_common.sh        # shared paths + pid→tty→pane + self-resolve helpers
│   ├── bus-register.sh       # register/refresh this session (auto-named)
│   ├── bus-send.sh           # drop a message (local, or over SSH to a peer machine)
│   ├── bus-recv.sh           # drain inbox, render as untrusted data  (backs /cm recv)
│   ├── bus-peers.sh          # list the registry
│   ├── bus-cleanup.sh        # prune dead-pid entries
│   ├── bus-deregister.sh     # remove one entry
│   ├── bus.sh                # /cm dispatcher (peers|ask|send|broadcast|recv|status)
│   ├── bus-hook-register.sh  # SessionStart hook
│   └── bus-hook-deregister.sh# SessionEnd hook
├── relay/claudemux-relay.sh  # the daemon (systemd --user)
├── registry/<name>.json      # live sessions (pid-anchored; no pane id stored)
├── mailbox/<name>/           # <epoch_ms>-<rand>.json messages + archive/
└── manual-patterns           # cwd globs that register manual (relay never types into them)
```

The message-bus terminology (`bus-*.sh`, "on the bus") is the accurate description of the mechanism:
Claudemux is a message bus; the `bus-*` scripts are its implementation.

### Registry — `registry/<name>.json`
One file per live session, written by the SessionStart hook:
```json
{ "name":"api", "machine":"host", "pid":962981, "tty":"/dev/pts/9",
  "cwd":"/home/user/api", "started":"…", "description":"", "mode":"auto" }
```
`pid` is the liveness anchor and what the relay resolves to a pane. **No pane id is stored.** `mode`
is `auto` (relay may wake it) or `manual` (relay never types into it).

### Mailbox — `mailbox/<name>/`
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
pid → tty → pane and types the wake. Dead targets are pruned on contact. Logs to `relay/relay.log`.

### Hooks
- **SessionStart** → `bus-hook-register.sh`: registers the session (auto-named), classifies mode
  from `manual-patterns`, and emits a one-line `additionalContext` note telling the session its bus
  name + current live peers. Fires on fresh start **and on `claude -c` resume**.
- **SessionEnd** → `bus-hook-deregister.sh`: removes the manifest.

### Slash command — `/cm`
`~/.claude/commands/cm.md` drives `bus.sh` **through the agent** (not a raw `!` shell expansion),
passing any free-text payload as a single quoted argument so the shell never interprets it.
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
{ "id":"1785037760123-515c", "from":"frontend", "to":"api", "machine":"host",
  "type":"query", "subject":"auth port", "body":"which port is auth on?",
  "reply_to":null, "timestamp":"…" }
```
- **query** expects a response (the reply wakes the asker). **response** carries `reply_to` (the
  query's id). **notify** is fire-and-forget. **broadcast** expands at send time into one notify per
  live session. Keep bodies small; send a file path, not a payload, for anything large.

## Liveness & pruning

A session is live iff its pid is running *and* resolves to a tmux pane. Pruning is belt-and-braces:
the relay deletes an entry the moment it tries to wake a dead target, and a systemd timer
(`claudemux-cleanup.timer`, every 5 min) sweeps the rest with `bus-cleanup.sh`.

## Naming & addressing

Auto-name = basename of the session's cwd, sanitized. Two sessions in the same directory get `name`,
`name-2`, … A session re-registering under the same pid (resume/clear) keeps its name; a dead
holder's name is reclaimed. Scripts resolve *your own* name from your pid, so nothing is hardcoded.
Use `/cm peers` to see the real names before addressing.

## Cross-machine

Address a peer explicitly as `name@machine` (an SSH host/alias). `bus-send.sh` drops the message
into that host's mailbox over SSH, computing the mailbox path from the **remote** host's
`$CLAUDEMUX_ROOT`/`$HOME` — so hosts with different home directories work. The peer's own relay wakes
the pane, and `bus-recv.sh` renders a `reply to: <from>@<sender-machine>` target so replies route
back. Without an explicit `@machine`, `bus-send.sh` falls back to the local registry's `machine`
field, then to this host. This reuses your existing SSH keys; verified host↔host in both directions.

Discovery is on-demand over SSH (no daemon, no sync): list peer hosts in `$CLAUDEMUX_ROOT/peers`
(SSH aliases, one per line). `bus-peers.sh` aggregates each peer's `--json` registry into `/cm peers`
(rows shown as `name@host`), and on a bare-name send that misses the local registry, `bus-send.sh`
probes each peer for `registry/<name>.json` and routes to the first match (use `name@host` to
disambiguate). `broadcast` is local-machine only.

## Why `send-keys`, not a headless run

An alternative is to resume the target session headlessly (`claude -c -p "…"`) to answer. That forks
a turn the live interactive pane never renders and races the session's transcript — wrong when a
human is watching that pane. `send-keys` drives the *real* session the user is looking at, so the
exchange shows up as visible turns in both panes.
