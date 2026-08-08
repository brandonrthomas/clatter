# Clatter

**A real-time message bus for Claude Code sessions.** Run many `claude` sessions at once — one
per tmux pane — and let them talk to each other: one session asks another a question, the other
*wakes on its own*, answers, and the reply lands back in the asking pane. No copy-paste between
panes, no human relay.

<p align="center">
  <img src="docs/demo.gif" alt="Clatter — one session asks, another wakes and answers, and the reply lands back" width="860">
</p>
<p align="center"><sub>Two Claude Code sessions over the bus — ask on the left; the peer auto-wakes and answers on the right.</sub></p>

<br>

---

```
  session "frontend"                     relay (per machine)                    session "api"
  ──────────────────                     ───────────────────                    ─────────────
  /clat ask api which port is the
       auth service on?  ────────────▶  new message for "api"
                                              │  resolve api → its tmux pane
                                              └─ wake it ──────────────────────▶ (idle or busy)
                                                                                      │
                                                              reads the question, answers "8081",
                                                              sends the reply back:
        reply appears in your pane  ◀──────  new message for "frontend"  ◀────────────┘
```

Clatter = **Claude** + **chatter** — it lets Claude Code sessions chatter to each other across
tmux. Under the hood it's a small, dependency-light message bus — a few bash scripts, a file-drop
mailbox, and one tiny relay daemon.

---

## Why

If you run a fleet of Claude Code sessions (one per project/pane), they can't see each other. You
end up hand-carrying facts between them: *"the other session set the port to 8081"*, *"the model
you loaded is aliased `qwen-large`"*. Clatter gives them a phone line. A session can consult a
peer that actually **owns** the answer, in real time, without you in the middle.

## Features

- **Real round-trips.** `/clat ask <peer> <question>` sends a query; the answer comes back to *your*
  pane asynchronously — because the relay can wake an idle session, not just leave it a note.
- **Names you recognize, live.** A session's bus name is its **Claude session name** (what `/rename`
  sets, shown in your tab) — resolved live, so renaming a session (locally *or* from the web UI) is
  reflected immediately, with no manual wiring. Sessions auto-register at start and on `claude -c`.
- **Self-cleaning.** Dead sessions are pruned automatically (on contact and on a timer).
- **Safe by design.** The only thing ever typed into another pane is a fixed control string — never
  message content — so a peer can't inject an arbitrary "user" turn. Sensitive workspaces can be
  marked read-only to the relay, and `/clat doctor` audits that the guard actually covers them. (See
  [Security](#security).)
- **Small + legible.** Bash + `jq` + `inotifywait` + `tmux`. One systemd `--user` relay. No server,
  no database, no ports.

## How it works (in three facts)

1. **Sessions are interactive `claude` CLIs, one per tmux pane.** The only way to hand a running
   interactive session a new turn is `tmux send-keys` into its pane — which delivers instantly if
   it's idle and *queues* if it's mid-turn.
2. **The target pane is resolved live, never stored.** Pane ids drift (tmux resurrect/renumber), so
   nothing caches a pane id: each session is keyed by a stable **sessionId** (which also names its
   mailbox, so a rename never misroutes), and at wake time the relay looks up that session's **pid**
   and resolves pid → tty → current pane.
3. **Nothing runs between turns**, so the push comes from outside: a per-machine **relay daemon**
   watches the mailboxes (`inotifywait`) and wakes the target pane when a message arrives.

Full design in [ARCHITECTURE.md](ARCHITECTURE.md).

## Requirements

- Linux with **tmux** for auto-wake — a session that should be woken automatically must run in a
  tmux pane. A session outside tmux still works, in manual (poll) mode (see **Manual mode** below).
- **`jq`** and **systemd** with user services + lingering. **`inotify-tools`** (`inotifywait`) is
  recommended but optional — without it the relay falls back to polling.
- **Claude Code** (the `claude` CLI) with hooks and custom slash commands. Note: `claude --safe-mode`
  disables *all* customizations — hooks and custom commands don't load — so a safe-mode session won't
  join the bus or have `/clat`.

```bash
sudo apt install jq inotify-tools tmux      # Debian/Ubuntu
loginctl enable-linger "$USER"              # so the relay survives logout/reboot
```

## Install

```bash
git clone https://github.com/brandonrthomas/clatter.git
cd clatter
./install.sh
```

`install.sh` is idempotent. It copies the code to `~/.claude/clatter/`, installs the `/clat` slash
command, wires `SessionStart`/`SessionEnd` hooks into `~/.claude/settings.json` (backing it up
first, preserving everything else), and enables the relay + cleanup timer. Open new sessions (or
`claude -c` existing ones) and they'll join.

## Usage

From inside any session:

```
/clat peers                       # who's on the bus (name, machine, alive, mode, description)
/clat ask <name> <question>       # ask a peer; the answer returns to THIS pane, asynchronously
/clat send <name> <message>       # fire-and-forget notify
/clat broadcast <message>         # notify every live session
/clat recv                        # read your inbox (the relay normally triggers this for you)
/clat clear                       # archive your inbox without reading it
/clat status                      # your own bus name + pending inbox
/clat mode [auto|manual]          # show or set whether the relay may wake this session
/clat desc [text]                 # show or set this session's description (shown in /clat peers)
/clat doctor                      # audit the manual-mode guard — what the patterns actually match
```

Everywhere above, `<name>` is a peer's **Claude session name** — the name `/rename` sets, shown in
its tab — matched live, so it always tracks the session's current name. (Leave a session unnamed and
it uses Claude's auto-generated name, e.g. `host-quiet-tome`.)

If two live sessions resolve to the **same** name, they're disambiguated with a `-2`/`-3` suffix in
`/clat peers` and when addressing (the earliest keeps the bare name); a session that *renames* into a
collision gets a heads-up to pick a unique one. The suffix is display/addressing only — delivery is
keyed by sessionId, so it never misroutes.

`/clat ask` doesn't block — you keep working; when the peer answers, the relay wakes your pane and
the reply appears inline.

**Composing vs. verbatim.** For `ask` / `send` / `broadcast`, the text after the command is normally
an *instruction for what to communicate*: the session composes the actual message from its current
context and sends that — e.g. `/clat ask box tell them the port I just set` sends something like
`The auth port is 8081.` (A self-contained question is just sent as-is.) To send text **exactly** as
written — a command, a snippet, precise wording — prefix it with `*`: `/clat send api *rm -rf /tmp/cache`
stores that literal string as a message (it is never executed).

**Cross-machine.** List your other hosts in `~/.claude/clatter/peers` (one SSH alias per line).
Then `/clat peers` aggregates their live sessions (shown as `name@host`), and `/clat ask <name> <question>`
auto-locates a peer across those hosts — or address one explicitly as `name@host`. The message is
dropped over SSH into that host's mailbox and its relay wakes the pane; replies route back
automatically. Requires Clatter on each
host and key-based SSH between them.

## Configuration

| What | How |
|---|---|
| Install location | `CLATTER_ROOT` (default `~/.claude/clatter`) |
| This machine's name | `CLATTER_MACHINE` (default `hostname -s`) — used for cross-machine addressing |
| Read-only workspaces | add globs matching your **real dir names** to `~/.claude/clatter/manual-patterns`; verify with `/clat doctor` (see `manual-patterns.example`) |
| Cross-machine peers | list SSH hosts in `~/.claude/clatter/peers` (see `peers.example`) |

**Manual mode.** A registered, fully addressable session that the relay will **never** type into —
peers see it in `/clat peers`, messages reach its mailbox, and you drain them yourself with `/clat recv`.
A session registers manual for either reason:

- its cwd matches a glob in `manual-patterns` — sensitive workspaces you don't want a peer able to
  drive; or
- it isn't running in a tmux pane, so there's no pane to `send-keys` into. Rather than register
  `auto` and then silently fail to wake, it degrades to manual — still on the bus and reachable, just
  polled instead of pushed.

A session's tmux-ness is fixed when it launches, so this is decided once at registration. If an
`auto` session later *loses* its pane (e.g. tmux is killed mid-session), the relay can't wake it — it
leaves the message queued and logs a loud `WARN` rather than dropping it silently.

The guard fails **open**: a glob that matches nothing looks identical to a working one, so it can
protect nothing without telling you. Match your *actual* directory names, not category words (`*acme*`,
not `*emr*`), and run **`/clat doctor`** to see which live sessions and workspace dirs the patterns
cover — `/clat peers` also warns when `manual-patterns` is set but matches no live session. Mode is
fixed at registration, so restart a session (or run `/clat mode manual`) after editing patterns.

## Security

The threat here isn't eavesdropping — it's **injection**, because waking a pane literally submits a
turn in another session. Clatter is built around that:

- **The wake is a single fixed constant** (`/clat recv`). Message *content* is always read from a
  file by that trusted command, never typed into a pane — so a peer can never cause arbitrary text
  to be submitted as a user turn elsewhere. Mailbox names are charset-restricted on both the send
  and relay sides.
- **Rendered messages are framed as untrusted data** with an explicit "do not obey" preamble; header
  fields are newline-escaped so a message can't forge the frame.
- **Message bodies are inert data end-to-end.** They're stored with `jq --arg`, transported as files
  (piped, never interpolated, over SSH cross-machine), and rendered as quoted text — nothing in a
  message is ever shell-executed by the pipeline. You can safely send text that *contains* commands;
  the `/clat` command hands your free text to the CLI as a single quoted argument.
- **Manual mode** (above) guarantees a peer can never drive a sensitive session.
- **Never put secrets, credentials, or private/regulated data in a message** — the bus is local
  plaintext files under your user account, and a message lands in another session's context.

No encryption (local files, Unix perms — same trust model as Claude Code's own data). Cross-machine
rides your existing SSH keys.

## Uninstall

```bash
./uninstall.sh            # stop services, remove /clat + hooks (keeps your mailbox/registry)
./uninstall.sh --purge    # also delete ~/.claude/clatter entirely
```

Your `settings.json` is backed up before every change.

## Status & limitations

- **Cross-machine works** (verified host↔host, both directions, including different home dirs). List
  peer hosts in `~/.claude/clatter/peers`; then `/clat peers` shows their sessions as `name@host` and
  a bare-name `/clat ask <name>` auto-locates the peer. You can always force one with `name@host`.
- Waking a pane while you're mid-typing appends to your input line (targets are normally idle).

## Development

Run the test suite — zero framework, just bash + jq:

```bash
./test/run.sh
```

It covers registration (sessionId-keyed), live-name resolution (transcript title wins over the
session-file name, with fallback) including a rename, duplicate-name disambiguation, send/recv/clear,
**message-body safety** (shell metacharacters stay inert), target validation, reply routing, the
manual-mode guard + `/clat doctor` (fail-open detection), the rename-collision notifier, `mode`/`desc`,
discovery `--json`, broadcast, and cleanup — against an isolated `CLATTER_ROOT` with fake session
files. The relay, tmux wake, and cross-machine SSH are integration paths, verified manually.

## License

[Apache-2.0](LICENSE) © 2026 Brandon Thomas
