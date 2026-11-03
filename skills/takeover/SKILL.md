---
name: takeover
description: Keeps your Claude Code work going when a Claude account runs out of quota. It closes the stopped session and continues the same conversation on another account that still has quota, or on another machine. Also shows one status board of every account, session and machine, brings back a session you marked to keep alive when its process dies, pins a session to its machine, lets background scripts pick an account and wait for quota, and stops everything with one command. Use when the owner runs /takeover, or asks to turn this on or off, to see the board or the accounts and their logins, to look at or attach to a resumed session, to move a session to another machine, to keep a session alive, to stop everything, or to keep working when an account hits its usage limit.
---

`udarnik` (on PATH) is the only entry point. While it is on, a single service watches every live interactive session
of every account, and a session whose account hit its limit is closed and resumed as a fork on an account with
quota (the fork is watched too, so it chains). Never investigate logs or account state by hand beyond what
`udarnik status` shows, unless the owner asks.

udarnik has two switches: the takeover of interactive sessions (`enabled`) and the account switching of runners
(headless `claude -p` workers that ask `udarnik account`, `runners`). `start` turns both on; `stop` turns only the
takeover off; `udarnik runners on|off` turns the runners switch alone.

When the machine has a fleet file (`status --fleet --json` lists more than one machine), udarnik works across
machines: one board for all, `--on MACHINE` runs a command on another machine, an account out of quota on one machine
is out on all, the weekly usage read on one machine is known on all, and a session whose machine has no account with
quota moves to another machine that has one, unless it is pinned to its machine. Every command below works from any
machine.

A kept session (`udarnik keep`) is one the service brings back, as the same session, when its process dies for any
reason but a usage limit (the takeover handles a limit): it first stops the systemd scope the session ran in, which ends
what the session left running, then resumes it in a scope of its own with a message. It happens only while the takeover
is on. Closing a kept session on purpose is a death like any other: `unkeep` it first.

Nobody looks at a clone's window. The service answers a permission dialog for an ask rule that only the clone's new
account has; any other dialog becomes an `ATTENTION` line. That dialog is one the original session would have shown
the owner too (its account asks for or denies the same rule), so never answer it for the clone: bring it to the
owner right away, with the clone's window and the command it waits on.

Report in the user's language as a short board, never raw JSON or logs. Color comes only from emoji. Show times
exactly as the tool gives them. Use exactly these icons:

| Item | Icon |
|---|---|
| service active / switch on | 🟢 |
| service stopped / switch off | ⚪ |
| account available | ✅ |
| account out of quota | ⛔ |
| session ok | 🔄 |
| session at the limit | 🛑 |
| clone alive | 🧬 |
| clone ended | ⚫ |
| worker (headless `claude -p`) | 🏗️ |
| runner waiting for quota | ⏳ |
| machine reachable / unreachable | 🖥️ / 📴 |
| session moved to another machine | 🚚 |
| session pinned to its machine | 📌 |
| session kept (brought back when its process dies) | ♻️ |

## `/takeover [context]`

1. Run `udarnik status --json` and show the board below (accounts, watched sessions, running workers, waiting runners). Sessions
   come with `pid`, `short`, `account`, `cwd`, `title`, `state` and `stopped_seconds`.
2. With a context text, decide which watched sessions it is about (match it against `title` and `cwd`) and pass
   their `short` ids as `--only id1,id2`. If nothing matches, or the text is not about specific sessions, do not
   pass `--only`. Never guess between several plausible sessions: list them and ask. When the owner names a project
   folder, pass it as `--root DIR` (only sessions at or below it are watched).
3. Run `udarnik start [--context "<the owner's text>"] [--only ...] [--root ...]` and report what it printed: the
   service state, the filter, that the account switching of runners is on too, and that the clones will appear on
   the clones' tmux server. Calling it again while
   the service is on only updates the context, the filter and the root; each call rewrites all three, so repeat the
   ones that must stay. When the owner names another machine, add `--on MACHINE`; when the owner wants it on every
   machine, use `--fleet` instead (`--root` is a folder of each machine, so never combine it with `--fleet`).
4. End with the viewing block (see below).

## `/takeover status`

Run `udarnik status --fleet --json`. It gives `machines`, one entry per machine (`name`, `self`, `reachable`,
`seen_at_local`, `status`). Render one block per machine, this machine first, under a heading with 🖥️ (or 📴 and
"last seen <seen_at_local>" for one that did not answer; its status is the last one seen), and inside each block,
from its `status`:

1. A heading line: service icon and state, takeover switch icon and state (`enabled`), runners switch icon and state
   (`runners`; `null` from an older udarnik: say "unknown"), the filter (`only`), the `root` when set and the owner
   context when present.
2. Accounts, one line each: ✅ or ⛔, the key, the weekly percentage (`weekly_percent`, noting how old the data is
   when `weekly_age_seconds` is above 3600, and the machine `weekly_from` when it is not this one), and the return
   time `out_until_local` for an account that is out.
3. A table of watched sessions `| | Pid | Id | Account | What | State | Stopped |`: 🔄 or 🛑 (and 📌 when `pinned`),
   `title` as "What", `stopped_seconds` as `N min` or `Xh YYmin`.
4. Clones: 🧬 or ⚫ (and 📌 when `pinned`), `original[0:8]` → `clone[0:8]`, the destination account, the `window`,
   `at_local`. A watched session with `kept` true also gets ♻️.
   Kept sessions (`kept`): ♻️ `short`, `title`, the account, 🧬 when `alive` or ⚫ when it stopped, the `scope` (`null`:
   none, so what it leaves running is not ended when it comes back), and `resumed` times back in the last hour (`last_resumed_local`).
   A kept session with no scope, or whose scope is shared (see the keep command), deserves a line saying so.
5. Workers (`workers`, headless `claude` processes, including the sessions registered with the `entrypoint` `sdk-cli`,
   a `claude -p`, which are never taken over or moved) with the account each runs on: 🏗️ pid, account, `cwd`. An
   account or folder of `null` means the system hides that process; say "unknown".
6. Runners waiting for quota (`waiting`, runners whose every account is out, waiting through `udarnik account wait`):
   ⏳ pid, `label`, `cwd`, and `until_local`, when the first account is back. They have no `claude` process while they
   wait, which is why they are not workers; they relaunch their call when an account is back.
7. Sessions moved to other machines (`moved`): 🚚 `original[0:8]` → `machine`, the account there, the `window`,
   `at_local`, and its `attach` alone in a fenced code block.
8. The tmux windows (`view.windows`), one item each: window name, alive or stopped, the session `short` it runs and
   what it does; under a live one, its `attach` alone in a fenced code block, so the owner copies that line and
   pastes it in a terminal to land on that window. A clone with `came_from` arrived from that machine: say so.
9. The last log lines only when something went wrong (a line containing `ATTENTION`) or when the owner asks.

The attach commands of another machine already go through `ssh -t`: show them exactly as given, they work from here.
An account is the same on every machine: say once that an account is out, not once per machine.

Omit empty sections. End with what needs the owner, if anything (for example: every account out, or a clone
that ended), and then, whenever a tmux server has a window, the viewing block: a line saying to paste it in a
terminal, the machine's `view.attach` alone in a fenced code block, then one line: `Ctrl+b w` switches window,
`Ctrl+b d` or closing the terminal leaves without ending anything, never `Ctrl+c` or `exit` inside a window, and
`/takeover view` opens that terminal by itself. Never put two commands in the same code block: pasting it would run
both.

## `/takeover view [window or id] [machine]`

Run `udarnik view [window or id]` (with `--on MACHINE` for a window of another machine) and relay what it printed: a terminal was opened on the tmux
server (on that session's window when one was given), or the attach command when there is no desktop. Add the
keys: `Ctrl+b w` switches window, `Ctrl+b d` or closing the terminal leaves without ending anything, and never
`Ctrl+c` or `exit` inside a window, which ends that session.

## `/takeover move <id> <machine>`

Moves a live session to another machine: `udarnik move <id> --to MACHINE` (add `--on M` when the session is on
machine M, not this one). Before running it, tell the owner what moves and what stays: the conversation goes, the
session is closed here and resumes as a fork there, in the same place of the project; changes not committed and
pushed, subagents and background tasks stay behind. Then report what it printed and give the attach command alone in
a fenced code block. If it says the other machine cannot take it (no such folder, no account with quota, no tmux),
nothing was closed: say why. Moving the session you run in ends you: say so before running it, and only when the
owner asked for exactly that.

A session that is pinned (`pinned` in the status) is refused with exit 1 and nothing closed: say it is pinned to its
machine and that `/takeover unpin <id>` lifts that, and never unpin it on your own.

## `/takeover pin <id> [machine]` and `/takeover unpin <id> [machine]`

Run `udarnik pin <id>` (or `unpin`), with `--on MACHINE` when the session is on another machine. A pinned session
changes accounts on its machine like any other but never moves to another machine, neither by a takeover across
machines nor by `move`; when no account there has quota, it waits there. Its clones are pinned too. `udarnik pins`
lists the pins. Report what it printed.

## `/takeover keep <id> [machine]` and `/takeover unkeep <id> [machine]`

Run `udarnik keep <id>` (or `unkeep`), with `--on MACHINE` when the session is on another machine; `<id>` is the start
of the id of a live session (the one in `status`). Report what it printed: whether the session runs in a scope of its
own (then what it left running dies when it is brought back) or not (then say how to get that: start the session with
`systemd-run --user --scope --unit=NAME claude`), and, when it said so, that the takeover is off and kept sessions
come back only while it is on. Keeping a session does not stop the owner from closing it: tell the owner to `unkeep`
first. A line with `ATTENTION kept session` in the log (resumed too many times in an hour, history or folder missing)
goes to the owner right away. The keep does not follow a session to another machine; the log says the command to keep
its clone there.

## `/takeover runners [on|off]`

The account switching of runners: headless workers that call `udarnik account current|limit` change to another account
when theirs runs out. Without an argument run `udarnik runners status`; otherwise `udarnik runners on` or `udarnik
runners off` (`--on MACHINE` for another machine, `--fleet` for every machine). Report the state it printed. It does
not touch the takeover of interactive sessions or the clones.

## `/takeover accounts`

Run `udarnik account list --json` (`--on` does not apply: for another machine, use `udarnik status --on MACHINE --json`
and its `accounts`). One line per account: the key, ✅ or ⛔, whether it is logged in (`logged_in`) and was opened
interactively once (`onboarded`), and the weekly usage with its age and origin. For an account not logged in or not
onboarded on a machine, say what the owner has to do there: log in with `CLAUDE_CONFIG_DIR=<path> claude` (`claude`
alone for `~/.claude`) and open it once.

The order in which runners and the takeover go to the next account is the owner's choice (`order.worker`,
`order.interactive` in the state folder, or `UDARNIK_ORDER_WORKER` and `UDARNIK_ORDER_INTERACTIVE`); never write one
unless the owner asks for exactly that order.

## `/takeover off`

Run `udarnik stop` (`--on MACHINE` for another machine, `--fleet` for every machine). Say that new takeovers are off,
that the existing clones keep running, that the service leaves by itself when none is left, and how to see them: the
viewing block. If `stop` printed that the account switching of runners stays on, say so too, and that
`/takeover runners off` turns it off.
`stop` ends neither the workers nor the waiting runners: when it printed `Still running here: ...`, report it per
machine (how many workers, how many runners waiting and until when) and that `udarnik stop --all` ends them. Never say
that nothing is running while `stop` listed anything.
Use `udarnik stop --all` (which ends the service and every clone, turns the runners switch off and ends the workers and
the waiting runners) only when the owner asks for it explicitly, and name the clones that will be closed before running
it.

### Stop everything

When the owner asks to stop everything ("parar tudo", "pare tudo", "pare urgente", or to stop the takeover and what
it runs), that is the explicit request for `udarnik stop --all --fleet`: run it, without asking again. Then run
`udarnik status --fleet --json` and report, per machine, anything still alive: the service, the clones, the workers
and the waiting runners (also what `stop --all` printed as `Still alive`, by pid). Say "stopped" only when every
machine shows none of them, and name the machine that does not answer (its status is only the last one seen).
