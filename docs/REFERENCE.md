# udarnik reference

The technical page of udarnik: every command and option, every environment variable, the state directory, the
account hook for runners, the waits, kept sessions, the fleet, and the tests. For what udarnik is, how it works in
plain words and how to use it every day, read the [README](../README.md) first.

## Contents

- [Requirements](#requirements)
- [Install, update, uninstall](#install-update-uninstall)
- [Commands](#commands)
- [How a takeover works](#how-a-takeover-works)
- [Safety](#safety)
- [Configuration](#configuration)
- [State directory](#state-directory)
- [The usage file](#the-usage-file)
- [When an account is back](#when-an-account-is-back)
- [Several machines](#several-machines)
- [Kept sessions](#kept-sessions)
- [Account hook for runners](#account-hook-for-runners)
  - [Preference order](#preference-order)
  - [Runner example](#runner-example)
- [Limits](#limits)
- [Tests](#tests)

## Requirements

- Linux with a systemd user manager (`systemctl --user` works), `tmux`, `jq`, `python3`, `flock` (util-linux),
  `setsid`, `systemd-run`, `tar`, bash 4 or newer. Several machines: `ssh` with keys between them.
- Claude Code, and two or more account config dirs on the same machine: `~/.claude` and `~/.claude-*`, each with
  its own `.credentials.json` (log in to each with `CLAUDE_CONFIG_DIR=~/.claude-work claude`).

## Install, update, uninstall

```
./install.sh              # install or update
./install.sh --force      # also replace a skills/takeover or a ~/.local/bin/udarnik that udarnik does not own
./install.sh --uninstall  # remove what install.sh installed
```

`install.sh` checks the requirements, copies `bin`, `lib` and `skills` to `~/.local/share/udarnik` (a fresh copy
through a staging folder and a rename), links `~/.local/bin/udarnik` to it, and installs the `/takeover` skill:

- if a shared folder exists (`~/.claude-shared`, see `UDARNIK_SHARED_DIR`), the skill goes to
  `<shared>/skills/takeover` and every account gets a symlink to it;
- otherwise the skill is copied into `<account>/skills/takeover` for every account.

A skill folder that udarnik owns carries a `.udarnik` marker file. A `skills/takeover` without the marker (a real
folder or a foreign symlink) is never touched unless `--force`; the skipped paths are printed.

The installer never restarts the service. When it is running, it keeps the old version until
`udarnik stop --all` and `udarnik start`. `--uninstall` runs `udarnik stop` (never `--all`) only if the service is
active, turns the account switching of runners off (a later install never finds it on; `udarnik runners on` turns it
on again), removes the command link, the installed tree and the marked skill folders and links, and keeps the state
directory (it prints where it is).

## Commands

| Command | What it does |
|---|---|
| `udarnik start [--context TEXT] [--only ID,ID] [--root DIR]` | Turn the takeover on, turn the [account hook for runners](#account-hook-for-runners) on, and start the service (one transient systemd user unit). `--context` is a note added to the message the clone receives. `--only` limits the takeover to sessions whose id starts with one of the prefixes (their clones are included). `--root` limits it to sessions whose folder is DIR or below it. Each call rewrites all three; an absent option is cleared. With the service already active, `start` only updates them. |
| `udarnik status [--json]` | Service, takeover switch and runners switch, accounts (available or out until, weekly usage with its age and the machine it came from), watched sessions (pinned and kept ones marked), clones, kept sessions, tmux windows, workers, runners waiting for quota, last log lines. `--json` is the machine form (`root` is `null` when unset; `runners` is `true` or `false`; `pinned` lists the pins; `kept` lists the kept sessions: `id`, `short`, `account`, `cwd`, `title`, `alive`, `pid`, `scope` (`null` when none), `resumed` in the last hour, `last_resumed`; `waiting` lists the runners waiting for quota: `pid`, `label`, `cwd`, `since`, `until`, `until_local`). |
| `udarnik stop [--all]` | Turn the takeover switch off: no new takeover; the service stays only while clones live. The account hook for runners stays on (it says so, and how to turn it off). It also says what still runs here that it does not stop: the workers (headless `claude`) and the runners waiting for quota. `--all` also turns the hook for runners off, ends the service and every clone, and ends the workers (TERM, KILL after `UDARNIK_STOP_WAIT` seconds) and the waiting runners (they leave by themselves once the hook is off); it prints how many it ended and, by pid, anything still alive, and exits 1 in that case. The process that asked and its ancestors are never ended, and sessions an app hosts (entrypoint `sdk-ts`) are not workers. |
| `udarnik runners on\|off\|status` | Turn the account hook for runners on or off by itself, or say whether it is on. It needs no service. |
| `udarnik view [WINDOW\|ID] [--print]` | Open a terminal attached to the clones' tmux server, on the window with that name, window id or session id prefix. Without a display, or with `--print`, it prints the attach command. Closing the terminal only detaches. |
| `udarnik move ID --to MACHINE` | Close a live session here and resume it on another machine of the fleet (see [Several machines](#several-machines)). A pinned session is refused (exit 1, nothing closed). |
| `udarnik pin ID`, `unpin ID`, `pins` | Pin the sessions whose id starts with ID to this machine: they change accounts here like any other, but never move to another machine, neither by a takeover across machines nor by `move`. The clone of a pinned session is pinned too, so the chain stays here, and the pin stays after the clone ends (the session can be resumed with its id and is still pinned). `unpin ID` removes the pins ID starts with (never the pins of other sessions that start with ID); `pins` lists them with the live session each one matches. |
| `udarnik keep ID`, `unkeep ID` | Keep the live session whose id starts with ID: when its process dies for any reason but a usage limit, the service brings it back (see [Kept sessions](#kept-sessions)). `keep` also records the systemd scope the session runs in; `unkeep ID` removes the kept sessions ID is the start of. `status` lists them (`kept` in `--json`). |
| `udarnik account <sub>` | The account hook for runners, below. |
| `--on MACHINE` | With `start`, `stop`, `status`, `runners`, `view`, `move`, `pin`, `unpin`, `pins`, `keep` and `unkeep`: run it on that machine of the fleet. |
| `--fleet` | With `start`, `stop`, `status` and `runners`: run it on every machine of the fleet; `status --fleet` shows one board per machine. |

The status gives every live tmux window its own attach command (`tmux -L udarnik attach -t udarnik:<window>`) and ends
with the one that attaches to all of them, alone on its line so it can be pasted in a terminal.

`workers` in the status are live headless `claude` processes (`-p` or `--print`) and the live sessions registered with
a headless `entrypoint` (see below), with the account each one runs on and its folder. For a process `/proc` hides,
and for a registered session, the account comes from the registry; both are `null` only when nothing knows them.

`waiting` in the status are the runners that called `udarnik account wait` (below): udarnik owns the wait, so it sees
them and `stop --all` ends them. A runner whose accounts were all out used to sleep on its own, and nothing could see
or stop it.

By default every live interactive session of every account is watched, in any directory. Times are shown in the
system's local zone (set `TZ` to change that).

What is watched and what is a worker: a session registered with the entrypoint `cli`, `sdk-ts`, `sdk-py`, `t3-code` or
any other is watched, and so is one with no entrypoint (older Claude Code, where the `kind` decides); a session with the
entrypoint `sdk-cli` (a headless `claude -p`, which Claude Code 2.1.316 still marks `interactive`) is a worker: never
watched or taken over, listed in `workers`. `UDARNIK_HEADLESS_ENTRYPOINTS` changes that list.

Only a terminal session (entrypoint `cli`, or none) is taken over. A session an app hosts (any other entrypoint: T3 Code's
`t3-code`, the Agent SDK's `sdk-ts` or `sdk-py`, the desktop app, an editor) is watched but never closed, cloned or kept:
the app owns its process and conversation, and a clone in tmux would run the same session twice. When one hits its
limit, the service logs `session X is hosted by Y and hit its usage limit ...` once and leaves it to the app.

## How a takeover works

1. Every `UDARNIK_POLL_SECONDS` (or at once, after `start`/`stop`) the service lists the live interactive sessions
   through `<account>/sessions/<pid>.json` and checks that each pid is the same process that wrote the file.
2. It reads the tail of the session history. A session is at the limit when its last answer is the usage-limit
   error, it happened while that process ran, and the account is still out (the reset time is in the error).
3. The account is marked out until the reset (see [When an account is back](#when-an-account-is-back)). The first
   available account of the `interactive` [order](#preference-order) is picked, else the available one with the
   lowest weekly usage (unknown usage goes last).
4. The original process is closed (TERM, KILL after 30 seconds) so its history is complete.
5. The history `<id>.jsonl` and the `<id>/` folder (subagents, tool results) are copied to the chosen account and
   compared.
6. A fork is resumed there (`claude --resume ID --fork-session`, with the same model, effort and permission mode
   when the history records them) in a window of the tmux server `udarnik`, with a message saying that it is a
   fork, why, that builders, subagents, background tasks and messages between sessions did not come along, to check
   the real state before relaunching anything, and the owner's context.
7. The clone's session id is recorded; from then on it is watched like any other session, so the chain continues.
   When no account here has quota, the session moves to the first other machine of the fleet that has one (see
   [Several machines](#several-machines)); when none has, or the session is pinned, nothing is closed and the next
   round tries again.

Accounts that share one projects folder (`<account>/projects` a link to the same folder) already see each other's
histories: nothing is copied in step 5.

The service leaves by itself when the switch is off and no clone is alive. The tmux server runs in its own
`systemd-run --user --scope`, so stopping the unit never kills a clone.

## Safety

- A clone only starts in an account where Claude Code was opened interactively on that machine
  (`hasCompletedOnboarding` in its `.claude.json`); otherwise it would stop on the first-run screens. The log says
  which account to open once.
- A clone whose account never trusted its folder is asked about it by Claude Code; the original session worked in
  that folder (or in its counterpart on another machine), so udarnik answers "Yes, I trust this folder".
- A clone runs under the settings of its new account and nobody looks at its window. udarnik answers Yes to a
  permission dialog only when it exists because of the move: an ask rule that the original account neither asks nor
  denies. Any other dialog is never answered; it is logged once as an `ATTENTION` line with the window to open.
- Every owner-attention line in `udarnik.log` carries the keyword `ATTENTION`.
- udarnik never calls an API. Its only network use is ssh to the machines of the fleet file, and without that file it
  uses no network at all. The weekly usage is only read from a file (see below), and learned from the other machines.
- The clones survive `udarnik stop` and the end of the service; only `udarnik stop --all` ends them.
- The clone is started with the command word `claude` (`UDARNIK_CLAUDE`), resolved through the service `PATH`
  when the window starts, never replaced by an absolute path, so a wrapper in `PATH` keeps applying.
- A real folder or file is never replaced when the shared memories and skills are linked (see `UDARNIK_LINKS`).

## Configuration

Every variable is read by the command and passed to the service by `udarnik start` (together with `PATH`, `HOME`
and `TZ`).

| Variable | Default | Meaning |
|---|---|---|
| `UDARNIK_UNIT` | `udarnik` | systemd user unit name (`<name>.service`). |
| `UDARNIK_TMUX_SOCKET` | `udarnik` | tmux socket name (`tmux -L`); the tmux session is `udarnik`. |
| `UDARNIK_STATE` | `${XDG_STATE_HOME:-~/.local/state}/udarnik` | State directory: the switches (`enabled`, `runners`), filters, `pinned`, `kept.json`, `order.<kind>`, `sessions.json`, per-account `out-until` and weekly usage, clone launchers, `udarnik.log`, the `snapshot` the service runs from. |
| `UDARNIK_POLL_SECONDS` | `120` | Seconds between rounds. |
| `UDARNIK_ACCOUNTS` | `~/.claude` and `~/.claude-*` that have `.credentials.json` | Colon-separated list of account dirs. |
| `UDARNIK_CLONE_WAIT_SECONDS` | `90` | How long to wait for a new clone to register its session. |
| `UDARNIK_CLONE_SCOPE` | `on` | `off` starts the tmux server directly instead of in its own `systemd-run --user --scope` (tests). |
| `UDARNIK_LINKS` | `on` | `off` disables linking the shared memories and skills into every account. |
| `UDARNIK_SHARED_DIR` | `~/.claude-shared` | Folder of memories and skills shared by the accounts, linked into each one when it exists. Never listed as an account. |
| `UDARNIK_USAGE_FILE` | `~/.cache/claude-statusline-usage-{key}.json` | Template of the file that holds a copy of the account's usage JSON; `{key}` is the account dir name without its leading dot. |
| `UDARNIK_ORDER_INTERACTIVE`, `UDARNIK_ORDER_WORKER` | (unset) | [Preference order](#preference-order) of a kind of caller: account keys separated by commas, colons or spaces. Wins over the state file `order.<kind>`. |
| `UDARNIK_HEADLESS_ENTRYPOINTS` | `sdk-cli` | Session entrypoints that are workers, never watched or taken over: separated by commas, colons or spaces. Empty: none. |
| `UDARNIK_CLAUDE` | `claude` | Command word used to start a clone or to resume a kept session. |
| `UDARNIK_KEEP_MESSAGE` | "This session stopped unexpectedly and was resumed. If you are a campaign host, run /campaign-host to register again and continue." | The message a kept session gets when it is resumed, and the one added to the message of the clone of a kept session. |
| `UDARNIK_KEEP_BACKOFF` | `120` | Seconds a kept session waits, after it came back, before it can be brought back again. |
| `UDARNIK_KEEP_MAX` | `5` | Most times a kept session is brought back in an hour. |
| `UDARNIK_FLEET` | `$AGENTIC_FLEET`, else `~/.config/agentic/fleet.json` | The fleet file (see [Several machines](#several-machines)). |
| `UDARNIK_MACHINE_ID` | `$AGENTIC_MACHINE_ID`, else `/etc/machine-id` | The id that names this machine in the fleet file. |
| `UDARNIK_SSH` | `ssh -o BatchMode=yes -o ConnectTimeout=10` | The ssh command used to reach the other machines (word-split). |
| `UDARNIK_FLEET_TAKEOVER` | `on` | `off`: a session whose machine has no account with quota waits there instead of moving to another machine. |
| `UDARNIK_FLEET_TIMEOUT` | `30` | Seconds `status --fleet` waits for each machine. |
| `UDARNIK_WAIT_SLICE` | `10` | Seconds between two looks of `udarnik account wait` at the switch and at the accounts (fractions allowed). |
| `UDARNIK_STOP_WAIT` | `15` | Seconds `stop --all` waits for the workers and the waiting runners to be gone before it kills the workers (fractions allowed). |
| `UDARNIK_TERMINAL` | (unset) | Command prefix used by `view` to open a terminal (word-split), before `xdg-terminal-exec` and `x-terminal-emulator -e`. |
| `UDARNIK_PREFIX` | `~/.local/share/udarnik` | Read by `install.sh` only: where the tree is installed. |

`udarnik view` opens a terminal only when `WAYLAND_DISPLAY` or `DISPLAY` is set and `--print` is not given; the
terminal is started detached with `setsid -f`.

## State directory

`UDARNIK_STATE` holds everything udarnik remembers. Every write happens under `flock`. `<key>` is the account
directory name without its leading dot.

| Path | Meaning |
|---|---|
| `enabled` | Switch of the takeover of interactive sessions: it works only while this file exists. |
| `runners` | Switch of the account hook for runners: `on` or `off`; absent is off, unless an `enabled` left by a version without this file exists (it counts as on). |
| `context`, `only`, `root` | The options of `start`: the owner note added to the takeover message, the session id prefixes (one per line) and the folder the takeover is limited to. |
| `accounts/<key>.out-until` | Epoch until which an account is out of quota. |
| `accounts/<key>.out-news` | When that epoch was learned and from which machine (none: here). Both files go away when a call works in the account. |
| `accounts/<key>.back-at` | Epoch of the newest call that worked in the account: an "out" news not newer than it is rejected. |
| `accounts/<key>.weekly` | The newest weekly usage known: percent, `resets_at`, time and machine. |
| `accounts/<key>.weekly-shared` | The last weekly usage of this machine told to the others. |
| `order.<kind>` | Preference order of the accounts for a kind of caller, one account key per line. |
| `waits/<pid>.json` | A runner waiting for quota (`udarnik account wait`): pid, start, label, folder, since, until. |
| `pinned` | Session id prefixes that never move to another machine, one per line. |
| `kept.json` | The kept sessions: id, account, folder, pid, start, scope, window, resumes. |
| `sessions.json` | The interactive sessions taken over. |
| `clones/` | The launchers and prompts of the clones. |
| `fleet-seen.json` | The last status seen from each machine of the fleet. |
| `snapshot/` | The copy of the tree the service runs from, so updating the installed tree never changes the script a running service reads. |
| `udarnik.log` | The single log. |

## The usage file

udarnik never calls `/api/oauth/usage` (on a machine where all Claude traffic must go through a proxy, a service
outside it would leak). It only reads a copy of that JSON response from the file named by `UDARNIK_USAGE_FILE`,
which something else keeps up to date, typically a status line script. It reads `limits[]` where
`kind == "weekly_all"` for `percent` (to pick the account with the lowest weekly usage) and `resets_at` (shown only);
the time of the data is the time of the file. Unknown usage means that account is picked last.

That file is only kept on a machine where a status line runs, so the weekly usage is shared by the fleet. Whatever
reads the file (the service round, `status`, `account current`, `pick` and `limit`) stores what is newer than the
last reading in `<state>/accounts/<key>.weekly` (percent, `resets_at`, time, machine) and tells the other machines,
by identity, through the same ssh as an account out of quota: only when the percent changed, and at most once every
10 minutes per account. A machine also learns it from `status --fleet`. Wherever it is read (pick, status, `account
list`), the newest of the file here and the reading learned is used; the status shows its age and the machine it came
from.

## When an account is back

The reset time of a usage-limit error is, in order: the text `resets <time> (<zone>)` (a text without a zone, like
`resets 3pm`, is read in the system zone; with something in parentheses that is not a zone name, it is not read),
then `quotaLimits.resetsAt` of the history entry, then one hour from now. The weekly reset of the usage file is never
used for a limit whose time is unknown: it overstates a 5-hour limit, and the fleet would learn that the account is
out until the end of the week. A runner that hits the limit again an hour later just marks it again.

Every out-until carries the time it was learned and the machine it came from. A newer news of the machine the known
one came from replaces it, even when it moves the time earlier, so a machine that guessed can correct itself. Between
machines the later time wins: a guess somewhere never frees an account another machine read is out longer. A limit
here without a reset time anywhere (the one-hour guess) never moves earlier an out-until still to come, and is not
told to the fleet. A news without a time (an older udarnik) only ever moves it later. An out-until that is over is
gone. Apart from the clear below, the time of a news is compared only with news of the same machine, so the clocks of
the machines need not agree.

The out-until is an estimate; a call that worked in the account is proof that it is back. So **a runner calls
`udarnik account clear [--at EPOCH] ACCOUNT [--kind KIND]` after every call that ended well in ACCOUNT** (the same
ACCOUNT it gave to `account limit`). `--at` is the time the call ended, as an epoch; without it, it is the time the
command was entered, read before anything else. A runner that clears some time after its call ended (a queue, a
retry) should pass it: a limit marked after `--at`, by another call, stays. An `--at` after the moment the command was
entered is refused (exit 2): a call cannot end in the future (a runner that passes milliseconds gets the error, not a
trace that would free every mark). When the account is not marked out, the command reads a file, keeps the time of the
call in `accounts/<key>.back-at` (see below) with shell builtins and exits 0, with no lock, no ssh and no process besides
udarnik's own start-up, so it is cheap to call every time. When it is, the out-until and its news are removed (unless the mark is newer than `--at`),
`account X is back (a call worked)` goes to the log, and every other machine is told by identity, in the background,
as with a limit (`account learn-clear IDENTITY KEY AT FROM`). A machine drops its mark only when the news of it is
older than the `AT` of the clear, whatever machine that news came from; a mark made after the call that worked stays
(and so does one of unknown time, left by an older udarnik). The clear that comes back from another machine with this
machine's name as its origin is ignored.

The clear leaves a trace so that it is not undone: each machine keeps the newest `AT` of a clear it knows
(`accounts/<key>.back-at`), even when it had no mark to remove (its own calls included: the cheap path above writes it
too), and rejects a news of "out" whose time is not newer than it. That is what stops a mark that an unreachable machine
kept, or that this machine missed, from coming back through a later `status --fleet` or a move, and a slow news of
"out" that arrives after the clear. The cheap path writes it without the lock, so two calls ending together may leave
the older time; the effect is one stale news accepted, until the next call. A time in the future (from another
machine's `learn-clear`) is taken as now, so the trace never runs ahead of the clock. A news of "out" without a time (an older udarnik) is
rejected only when its out-until is not later than that `AT`; a limit marked here and now always wins. The clear is
not carried by `status --fleet`: the direct news is enough, and a machine that was unreachable keeps its mark (and
does not pass it on) until its out-until, or a limit, replaces it.

The clear is the one place where times of different machines are compared (the `AT` of a clear of one machine against
the news of "out" of another), so for it **the clocks of the fleet must be synchronized (NTP)**: a clock ahead frees
a mark that was made after the call, a clock behind leaves an old mark in place.

## Several machines

With a fleet file, every machine is driven from any of them: one board for all, `--on MACHINE` for start, stop, status,
view and move, an account out of quota on one machine is out on all of them, and when no account on a machine has quota
its session moves to another machine that has one.

udarnik reads the machines of the fleet file that stakhanov's `campaign fleet` keeps (one file for everything):

```json
{"machines": {"kepler": {"ssh": "kepler", "id": "<machine id>"}, "box": {"ssh": "box", "id": "<machine id>"}},
 "projects": {"App": {"paths": {"kepler": "/home/me/app", "box": "/srv/me/app"}}}}
```

A machine knows which entry it is by its machine id (`/etc/machine-id`). Each machine runs its own udarnik (installed
there, with `tmux`) and reaches the others over ssh with keys (`BatchMode`: no password prompts).

- **One board.** `udarnik status --fleet` asks every machine at once and shows one board per machine. A machine that
  does not answer shows the last status seen from here, with its time. `--json` gives `{machines:[{name, self,
  reachable, seen_at, status}]}`.
- **Control from anywhere.** `start`, `stop`, `status`, `runners`, `view`, `move`, `pin`, `unpin` and `pins` take
  `--on MACHINE`; `start`, `stop`, `status` and `runners` take `--fleet`. What another machine prints for a person to
  paste goes through `ssh -t <that machine>`, so `udarnik view --on box` opens a terminal here on box's tmux.
- **Shared account state.** The same account has the same identity on every machine (`oauthAccount` in its
  `.claude.json`), whatever its folder is called. When an account hits its limit (a session or a runner's `account
  limit`), every other machine is told at once, in the background, with the time and the machine of that news (the
  newest wins, see [When an account is back](#when-an-account-is-back)). A machine that was unreachable learns it at
  its own next limit, at a move, or from a `status --fleet` run anywhere. An account that is back because a call
  worked (`account clear`) is told the same way, but only directly. The weekly usage is shared the same way (see
  [The usage file](#the-usage-file)).
- **Moving a session.** `udarnik move ID --to MACHINE` asks the other machine whether it can take the session (its
  folder exists there and an account has quota), closes the session here, sends the history over ssh and resumes a
  fork in that machine's tmux, with a message saying where it came from. The folder is the same place inside a
  project the fleet file maps on both machines (`/home/me/app/web` here is `/srv/me/app/web` on box), else the same
  path. Only the conversation moves: changes that were not committed and pushed stay on the old machine, and the fork
  is told to check. The status of the old machine lists the session under "Moved to other machines" with the command
  that attaches to it. A `move` run from inside the session it moves goes on detached.
- **Takeover across machines.** When a session hits its limit and no account on its machine has quota, it moves the
  same way to the first other machine that has one.
- **Pinned sessions.** A session that needs its machine (for example one that works on a checkout only that machine
  has) is pinned there with `udarnik pin ID`: it changes accounts on its machine like any other, but never moves, by a
  takeover across machines or by `move` (which refuses with exit 1 and closes nothing). When no account there has
  quota, it waits there. Its clones are pinned too.

## Kept sessions

A session that hosts other work (for example an interactive session whose background subagents run a campaign) must
come back when it dies, and what it started must not keep running without it. `udarnik keep ID` marks a live session
(an id prefix) as kept. While the takeover is on, every round of the service looks at the kept sessions; one whose
registered process is gone (the pid is not alive, or its start time changed) and whose history does not end at a
usage limit is brought back:

1. If the process ran in a systemd scope that is still active, the service stops that scope: what the session left
   running (the commands of its subagents, reparented to the user's systemd when the process died, but still in the
   scope's cgroup) dies with it. It is logged.
2. The session is resumed with `claude --resume ID` (no fork: the same session, in the same account and folder, with
   its model, effort and permission mode) in a window `k-<id8>` of the tmux server of the service, in a scope of its
   own (`systemd-run --user --scope --unit=udarnik-keep-<id8>-<epoch>`), with a message (`UDARNIK_KEEP_MESSAGE`) that
   says it stopped unexpectedly and that a campaign host runs `/campaign-host` again. Claude Code itself tells the
   resumed session which background agents did not finish.
3. The new process and its new scope replace the old ones in the keep, so the next death is cleaned the same way.

To have step 1, start the session in a scope of its own: `systemd-run --user --scope --unit=NAME claude ...`; `keep`
reads the scope from `/proc/<pid>/cgroup` and says what it found. A session that runs in a scope shared with other
things (a login session `session-N.scope`, an application or terminal scope `app-*.scope`, a pane
`tmux-spawn-*.scope`, `vte-spawn-*.scope`, `init.scope`) is still resumed, but that scope is never stopped. A session
without a scope is resumed too; what it left running is not ended.

- A session that dies at a usage limit is not resumed by this path: the takeover moves a live one to another account,
  and a dead one is resumed here once the limit is over.
- It comes back at most once per `UDARNIK_KEEP_BACKOFF` seconds, and at most `UDARNIK_KEEP_MAX` times per hour; when
  that stops it the log gets one `ATTENTION` line with the command to look at it.
- The takeover of a kept session that hit its limit stops the original's scope first (its orphans die), starts the
  fork in a scope of its own, moves the keep to the fork (the clone is the new host) and appends the same message to
  the clone's.
- The keep does not follow a session that moves to another machine: it is dropped, and the log says how to keep the
  clone there (`udarnik keep CLONE --on MACHINE`).
- A session the owner resumed by hand is registered again, not resumed twice. To end a kept session for good, `unkeep`
  it first: closing it is a death like any other.
- Nothing comes back while the takeover is off or the service is not running: `stop` and `stop --all` keep the list
  (`stop --all` ends the service), and the kept sessions come back after the next `start`. The `--only` and `--root`
  filters do not apply to kept sessions.

## Account hook for runners

Campaign runners, schedulers or any script that calls `claude -p` can share the same account state. Their switch is
not the takeover's: `udarnik runners on|off` (or `start`, which turns both on). It is never on by default, whatever
the number of accounts; `udarnik stop` leaves it on and `udarnik stop --all` turns it off. A takeover switch left on
by a version without the runners switch counts as the runners on, until the next `runners off` or `stop --all`.

| Command | Result |
|---|---|
| `udarnik account enabled` | Exit 0 if the runners switch is on, 1 otherwise. |
| `udarnik account current [--kind KIND]` | The account dir for the caller's environment (`CLAUDE_CONFIG_DIR`, else `~/.claude`) while it has quota; when the runners switch is on and that account is out, the next one (see the order below). |
| `udarnik account limit [--kind KIND] ACCOUNT` | Reads the failure text on stdin (the text, or the JSON of `claude -p --output-format json`). Exit 1 and no output if it is not a usage-limit message. Otherwise marks ACCOUNT out until the reset (see [When an account is back](#when-an-account-is-back)) and prints the next available account (exit 0), or exits 75 when none is available. |
| `udarnik account clear [--at EPOCH] [--kind KIND] ACCOUNT` | To call after a call that ended well in ACCOUNT, which ended at EPOCH (default: when the command was entered). An EPOCH after the command was entered is refused (exit 2). When ACCOUNT is not marked out: exit 0, no ssh, and EPOCH is only kept as the trace (`back-at`). Otherwise removes the out-until (unless a limit was marked after EPOCH), logs `account X is back (a call worked)` and tells the fleet (see [When an account is back](#when-an-account-is-back)). `--kind` is accepted and has no effect. |
| `udarnik account next` | Epoch at which the first account is available again (now if one already is). |
| `udarnik account wait [--label TEXT]` | The wait of a runner whose every account is out (`account limit` exited 75). Exit 1 at once, printing nothing, when the runners switch is off. Otherwise it registers itself in `<state>/waits/<pid>.json` (shown by `status`, ended by `stop --all`), looks every `UDARNIK_WAIT_SLICE` seconds and exits 0 as soon as an account is available (also one cleared, or learned from another machine, meanwhile) or 1 when the runners switch has been turned off. It prints nothing and leaves two log lines. |
| `udarnik account env ACCOUNT` | The env prefix that runs a command in ACCOUNT: `env -u CLAUDE_CONFIG_DIR` for `~/.claude`, else `env CLAUDE_CONFIG_DIR=...` (shell-quoted; use `eval` to run it). |
| `udarnik account pick [--kind KIND] [EXCLUDE...]` | The available account to go to: the first of the order of KIND, else the one with the lowest weekly usage. |
| `udarnik account list [--json]` | One line (with `--json`, one object of an array) per account: `key`, `path`, `identity` (`accountUuid/organizationUuid`), `logged_in` (it has `.credentials.json`), `onboarded` (`hasCompletedOnboarding`), `available`, `out_until`, `weekly_percent`, `weekly_age_seconds` and `weekly_from`. It reads files only, never the network: what a new machine still needs (a login, a first interactive run). |
| `udarnik account learn IDENTITY KEY EPOCH [FROM [AT]]` | Record that the account IDENTITY (KEY on the other machine) is out until EPOCH, as FROM learned it at AT; used between machines. |
| `udarnik account learn-clear IDENTITY KEY AT FROM` | Record that a call worked at AT in the account IDENTITY (KEY on the other machine), as FROM saw it: the out-until is removed when its news is older than AT, and AT is kept so that a news of "out" not newer than it is rejected later. Ignored when FROM is this machine; used between machines. |
| `udarnik account learn-weekly IDENTITY KEY PERCENT RESETS_AT AT FROM` | Record the weekly usage FROM read at AT; used between machines. |

### Preference order

`current`, `pick` and `limit` take `--kind interactive` or `--kind worker`, the kind of caller; the takeover of
interactive sessions uses `interactive`. The order of a kind is `UDARNIK_ORDER_<KIND>` (`UDARNIK_ORDER_WORKER=claude-work,claude`)
or, without it, the file `<state>/order.<kind>`, one account key per line:

```
claude-work
claude
```

When the caller's account runs out, the next account is the first available one of that order; accounts outside it
come after, by the lowest weekly usage. The order never moves a caller whose account still has quota. Without a file
and a variable, or without `--kind`, the choice is the lowest weekly usage, as always. udarnik ships no order: which
account each kind uses first is the owner's choice.

### Runner example

A runner that repeats a headless call on the next account when the current one is out of quota, and waits through
`udarnik account wait` (never a sleep of its own: it would be invisible to `status` and to `stop`) when every account is out:

```bash
failover=false account='' label='nightly batch'   # the label is what status shows for the wait
if udarnik account enabled; then
  failover=true
  account=$(udarnik account current --kind worker)
fi
while :; do
  set +e
  (
    if $failover; then
      if [[ $account == "$HOME/.claude" ]]; then unset CLAUDE_CONFIG_DIR; else export CLAUDE_CONFIG_DIR=$account; fi
    fi
    claude -p "$prompt" >"$out" 2>"$err"
  )
  code=$?
  set -e
  (( code != 0 )) || break
  $failover || break
  status=0
  next=$(cat "$out" "$err" | udarnik account limit --kind worker "$account") || status=$?
  case $status in
    0) account=$next ;;                                   # limit hit: repeat the call on the next account
    75) # every account is out: wait here, seen and stoppable; repeat the call if one is back, stop otherwise
        udarnik account wait --label "$label" || exit 75
        account=$(udarnik account current --kind worker) ;;
    *) break ;;                                           # not a usage-limit failure
  esac
done
```

## Limits

udarnik relies on Claude Code internals, verified with Claude Code 2.1.311: the per-process session file
`<account>/sessions/<pid>.json`, the history `<account>/projects/<slug>/<id>.jsonl` (including the entry fields that
mark the usage-limit error), `claude --resume ID --fork-session`, and the text of the permission dialog
(`Permission rule ... requires confirmation`, `1. Yes`, `Esc to cancel`). A Claude Code release that changes any of
them can stop the detection or the dialog handling; the tests use fakes and do not prove the real client.

A takeover does not carry over anything that lived outside the history: builders, subagents, background tasks and
messages between sessions of the old session are gone, which is why the clone is told to check the real state.

## Tests

```
bash tests/udarnik.sh
```

Deterministic, no network, no real account: every case uses a temporary `HOME`, a fake `claude`, fake sessions, a
per-run tmux socket and unit name (`udarnik-test-<pid>`), `UDARNIK_CLONE_SCOPE=off`, and stubs for `systemctl` and
`systemd-run` (which, with `--scope`, runs the command in place and records an active scope that `systemctl stop`
ends) and, for the kept sessions, `UDARNIK_PROC` (tests only), the folder that holds the `<pid>/cgroup` files of its
fake processes. A second machine is another temporary `HOME` reached through a fake ssh. It also runs `install.sh` in
temporary homes. The JSON a headless call prints at a usage limit comes from `tests/fixtures/` (made up until a real
one is captured).

Nothing of the caller's environment reaches a test: every `UDARNIK_` and `AGENTIC_` variable, the XDG folders,
`TMUX` and `BASH_ENV` are dropped first (a shell inside a clone of the real service inherits that service's
variables), and the tmux servers live in a folder of the run (`TMUX_TMPDIR`). The battery has one clock: a `date` of
its own in `PATH`, and udarnik's builtin clock through `UDARNIK_CLOCK_OFFSET` (tests only), so
`UDARNIK_TEST_NOW=23:59:30 bash tests/udarnik.sh` runs it as if it had started then (any date `date -d` reads).
The battery's `ps` and `pgrep` see only its own processes (below it and below its tmux servers), so no real
`claude` process of the machine is ever read.

```
bash tests/isolation.sh
```

runs the battery inside a poisoned "real" environment (a state with an account out and a log of ISO lines, a fleet,
an ssh, a live tmux server named `udarnik`, canaries for `udarnik`, `claude`, `ssh` and `systemctl` in `PATH`) and
checks that it passes, that none of it changed or ran, and, with `strace` or else a `LD_PRELOAD` tracer built with
`cc`, that no file outside `/tmp`, `/proc`, `/dev` and the system folders was opened, run, created or removed, that
no `/proc/<pid>` of a process outside the battery was opened, and that nothing of the poisoned environment was.
