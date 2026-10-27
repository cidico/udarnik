---
name: takeover
description: Keep Claude Code sessions going on another account when an account hits its usage limit (turn it on, status board, view the clones, turn it off). Use when the owner runs /takeover, or asks to keep their sessions running when a Claude account runs out of quota.
---

`udarnik` (on PATH) is the only entry point. While it is on, a single service watches every live interactive session
of every account, and a session whose account hit its limit is closed and resumed as a fork on an account with
quota (the fork is watched too, so it chains). Never investigate logs or account state by hand beyond what
`udarnik status` shows, unless the owner asks.

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

## `/takeover [context]`

1. Run `udarnik status --json` and show the board below (accounts, watched sessions, running workers). Sessions
   come with `pid`, `short`, `account`, `cwd`, `title`, `state` and `stopped_seconds`.
2. With a context text, decide which watched sessions it is about (match it against `title` and `cwd`) and pass
   their `short` ids as `--only id1,id2`. If nothing matches, or the text is not about specific sessions, do not
   pass `--only`. Never guess between several plausible sessions: list them and ask. When the owner names a project
   folder, pass it as `--root DIR` (only sessions at or below it are watched).
3. Run `udarnik start [--context "<the owner's text>"] [--only ...] [--root ...]` and report what it printed: the
   service state, the filter, and that the clones will appear in the tmux server it names (`udarnik view`).
   Calling it again while the service is on only updates the context, the filter and the root; each call rewrites
   all three, so repeat the ones that must stay.
4. End with the viewing line (see below).

## `/takeover status`

Run `udarnik status --json` and render:

1. A heading line: service icon and state, switch icon and state, the filter (`only`), the `root` when set and the
   owner context when present.
2. Accounts, one line each: ✅ or ⛔, the key, the weekly percentage (`weekly_percent`, noting how old the data is
   when `cache_age_seconds` is above 3600), and the return time `out_until_local` for an account that is out.
3. A table of watched sessions `| | Pid | Id | Account | What | State | Stopped |`: 🔄 or 🛑, `title` as "What",
   `stopped_seconds` as `N min` or `Xh YYmin`.
4. Clones: 🧬 or ⚫, `original[0:8]` → `clone[0:8]`, the destination account, the `window`, `at_local`.
5. Workers (`workers`, headless `claude` processes) with the account each runs on: 🏗️ pid, account, `cwd`. An
   account or folder of `null` means the system hides that process; say "unknown".
6. The tmux windows (`view.windows`): window name, alive or stopped, and the session `short` it runs.
7. The last log lines only when something went wrong (a line containing `ATTENTION`) or when the owner asks.

Omit empty sections. End with what needs the owner, if anything (for example: every account out, or a clone
that ended), and then, whenever the tmux server has a window, the viewing line: `/takeover view` (or
`udarnik view`) opens a terminal on the sessions, `Ctrl+b w` switches window, and closing the
terminal or `Ctrl+b d` leaves without ending anything.

## `/takeover view [window or id]`

Run `udarnik view [window or id]` and relay what it printed: a terminal was opened on the tmux
server (on that session's window when one was given), or the attach command when there is no desktop. Add the
keys: `Ctrl+b w` switches window, `Ctrl+b d` or closing the terminal leaves without ending anything, and never
`Ctrl+c` or `exit` inside a window, which ends that session.

## `/takeover off`

Run `udarnik stop`. Say that new takeovers are off, that the existing clones keep running, that
the service leaves by itself when none is left, and how to see them (`udarnik view`).
Use `udarnik stop --all` (which ends the service and every clone) only when the owner asks for it
explicitly, and name the clones that will be closed before running it.
