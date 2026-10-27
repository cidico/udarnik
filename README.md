# udarnik

When one of your Claude Code accounts hits its usage limit, the next account takes the shift. udarnik watches your
interactive Claude Code sessions; when the last answer of one is the usage-limit error, it closes that process,
copies its history to an account that still has quota and resumes a fork of it there, in a window of a private
tmux server. The clone is watched too, so it chains from account to account. A skill, `/takeover`, drives it from
inside Claude Code.

The name: an *udarnik* was a Soviet "shock worker", the one who never stopped working. Here the next account takes
the shift.

## Requirements

- Linux with a systemd user manager (`systemctl --user` works), `tmux`, `jq`, `python3`, `flock` (util-linux),
  `setsid`, `systemd-run`, bash 4 or newer.
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
active, removes the command link, the installed tree and the marked skill folders and links, and keeps the state
directory (it prints where it is).

## Commands

| Command | What it does |
|---|---|
| `udarnik start [--context TEXT] [--only ID,ID] [--root DIR]` | Turn the takeover on and start the service (one transient systemd user unit). `--context` is a note added to the message the clone receives. `--only` limits the takeover to sessions whose id starts with one of the prefixes (their clones are included). `--root` limits it to sessions whose folder is DIR or below it. Each call rewrites all three; an absent option is cleared. With the service already active, `start` only updates them. |
| `udarnik status [--json]` | Service and switch, accounts (available or out until, weekly usage), watched sessions, clones, tmux windows, workers, last log lines. `--json` is the machine form (`root` is `null` when unset). |
| `udarnik stop [--all]` | Turn the switch off: no new takeover; the service stays only while clones live. `--all` also ends the service and every clone. |
| `udarnik view [WINDOW\|ID] [--print]` | Open a terminal attached to the clones' tmux server, on the window with that name, window id or session id prefix. Without a display, or with `--print`, it prints the attach command. Closing the terminal only detaches. |
| `udarnik account <sub>` | The account hook for runners, below. |

`workers` in the status are live headless `claude` processes (`-p` or `--print`) with the account each one runs on
and its folder; both are `null` when `/proc` hides the process.

By default every live interactive session of every account is watched, in any directory. Times are shown in the
system's local zone (set `TZ` to change that).

## How a takeover works

1. Every `UDARNIK_POLL_SECONDS` (or at once, after `start`/`stop`) the service lists the live interactive sessions
   through `<account>/sessions/<pid>.json` and checks that each pid is the same process that wrote the file.
2. It reads the tail of the session history. A session is at the limit when its last answer is the usage-limit
   error, it happened while that process ran, and the account is still out (the reset time is in the error).
3. The account is marked out until the reset. The available account with the lowest weekly usage is picked
   (unknown usage goes last).
4. The original process is closed (TERM, KILL after 30 seconds) so its history is complete.
5. The history `<id>.jsonl` and the `<id>/` folder (subagents, tool results) are copied to the chosen account and
   compared.
6. A fork is resumed there (`claude --resume ID --fork-session`, with the same model, effort and permission mode
   when the history records them) in a window of the tmux server `udarnik`, with a message saying that it is a
   fork, why, that builders, subagents, background tasks and messages between sessions did not come along, to check
   the real state before relaunching anything, and the owner's context.
7. The clone's session id is recorded; from then on it is watched like any other session, so the chain continues.
   When no account has quota, nothing is closed and the next round tries again.

The service leaves by itself when the switch is off and no clone is alive. The tmux server runs in its own
`systemd-run --user --scope`, so stopping the unit never kills a clone.

## Safety

- A clone runs under the settings of its new account and nobody looks at its window. udarnik answers Yes to a
  permission dialog only when it exists because of the move: an ask rule that the original account neither asks nor
  denies. Any other dialog is never answered; it is logged once as an `ATTENTION` line with the window to open.
- Every owner-attention line in `udarnik.log` carries the keyword `ATTENTION`.
- udarnik never makes a network call. The weekly usage is only read from a file (see below).
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
| `UDARNIK_STATE` | `${XDG_STATE_HOME:-~/.local/state}/udarnik` | State directory: switch, filters, `sessions.json`, per-account `out-until`, clone launchers, `udarnik.log`, the `snapshot` the service runs from. |
| `UDARNIK_POLL_SECONDS` | `120` | Seconds between rounds. |
| `UDARNIK_ACCOUNTS` | `~/.claude` and `~/.claude-*` that have `.credentials.json` | Colon-separated list of account dirs. |
| `UDARNIK_CLONE_WAIT_SECONDS` | `90` | How long to wait for a new clone to register its session. |
| `UDARNIK_CLONE_SCOPE` | `on` | `off` starts the tmux server directly instead of in its own `systemd-run --user --scope` (tests). |
| `UDARNIK_LINKS` | `on` | `off` disables linking the shared memories and skills into every account. |
| `UDARNIK_SHARED_DIR` | `~/.claude-shared` | Folder of memories and skills shared by the accounts, linked into each one when it exists. Never listed as an account. |
| `UDARNIK_USAGE_FILE` | `~/.cache/claude-statusline-usage-{key}.json` | Template of the file that holds a copy of the account's usage JSON; `{key}` is the account dir name without its leading dot. |
| `UDARNIK_CLAUDE` | `claude` | Command word used to start a clone. |
| `UDARNIK_TERMINAL` | (unset) | Command prefix used by `view` to open a terminal (word-split), before `xdg-terminal-exec` and `x-terminal-emulator -e`. |
| `UDARNIK_PREFIX` | `~/.local/share/udarnik` | Read by `install.sh` only: where the tree is installed. |

`udarnik view` opens a terminal only when `WAYLAND_DISPLAY` or `DISPLAY` is set and `--print` is not given; the
terminal is started detached with `setsid -f`.

### The usage file

udarnik never calls `/api/oauth/usage` (on a machine where all Claude traffic must go through a proxy, a service
outside it would leak). It only reads a copy of that JSON response from the file named by `UDARNIK_USAGE_FILE`,
which something else keeps up to date, typically a status line script. It reads `limits[]` where
`kind == "weekly_all"` for `percent` (to pick the account with the lowest weekly usage) and `resets_at` (when the
error text has no readable reset). A missing file means unknown usage: that account is picked last.

## Account hook for runners

Campaign runners, schedulers or any script that calls `claude -p` can share the same switch and account state:

| Command | Result |
|---|---|
| `udarnik account enabled` | Exit 0 if the switch is on, 1 otherwise. |
| `udarnik account current` | The account dir for the caller's environment (`CLAUDE_CONFIG_DIR`, else `~/.claude`); when the switch is on and that account is out, the best available other one. |
| `udarnik account limit ACCOUNT` | Reads the failure text on stdin. Exit 1 and no output if it is not a usage-limit message. Otherwise marks ACCOUNT out until the parsed reset and prints the best available other account (exit 0), or exits 75 when none is available. |
| `udarnik account next` | Epoch at which the first account is available again (now if one already is). |
| `udarnik account env ACCOUNT` | The env prefix that runs a command in ACCOUNT: `env -u CLAUDE_CONFIG_DIR` for `~/.claude`, else `env CLAUDE_CONFIG_DIR=...` (shell-quoted; use `eval` to run it). |
| `udarnik account pick [EXCLUDE...]` | The available account with the lowest weekly usage. |

A runner that repeats a headless call on the next account when the current one is out of quota:

```bash
failover=false account=''
if udarnik account enabled; then
  failover=true
  account=$(udarnik account current)
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
  next=$(cat "$out" "$err" | udarnik account limit "$account") || status=$?
  case $status in
    0) account=$next ;;                                   # limit hit: repeat the call on the next account
    75) echo "no account has quota until $(date -d "@$(udarnik account next)")" >&2; exit 75 ;;
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
`systemd-run`. It also runs `install.sh` in temporary homes.
