#!/usr/bin/env bash
# Deterministic tests of lib/accounts.sh, bin/udarnik and install.sh. Never touches a real account, real state, a
# real session or a real service: HOME, the account directories and the state directory are temporary, `claude` is
# a fake, tmux has its own socket, and systemctl/systemd-run are stubs. Run: bash tests/udarnik.sh

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d)
socket="udarnik-test-$$"
test_now=${UDARNIK_TEST_NOW:-}
# Nothing of the caller's environment reaches a test. A battery run from a clone of the real service inherits that
# service's variables (its UDARNIK_STATE, its tmux socket, the switch that sent its log lines to stdout), and any
# shell has the real XDG folders: every UDARNIK_ and AGENTIC_ variable is dropped, and what is needed is set below.
for variable in $(compgen -e | grep -E '^(UDARNIK_|AGENTIC_)' || true); do unset "$variable"; done
unset CLAUDE_CONFIG_DIR TMUX TMUX_PANE BASH_ENV ENV XDG_STATE_HOME XDG_CACHE_HOME XDG_DATA_HOME
# The one clock of the battery: every time a test or udarnik reads (`date`, and udarnik's builtin clock through
# UDARNIK_CLOCK_OFFSET) is the real clock moved by the same offset, as if the battery had started at UDARNIK_TEST_NOW
# (any date `date -d` reads: "02:20", "2026-11-02 23:59:30"). Unset, it is the real time. A date the tests or udarnik
# give to `date -d` is read as of that clock: a time of day on its day, a month and day in its year.
real_date=$(command -v date)
clock_offset=0
[[ -z $test_now ]] || clock_offset=$(( $("$real_date" -d "$test_now" +%s) - $("$real_date" +%s) ))
export UDARNIK_CLOCK_OFFSET=$clock_offset
mkdir -p "$test_root/clock"
printf '#!/usr/bin/env bash\nreal=%q\n' "$real_date" >"$test_root/clock/date"
cat >>"$test_root/clock/date" <<'FAKE'
# date on the battery's clock: the real date, UDARNIK_CLOCK_OFFSET seconds later.
offset=${UDARNIK_CLOCK_OFFSET:-0}
[[ $offset =~ ^-?[0-9]+$ ]] && ((offset != 0)) || exec "$real" "$@"
now=$(( $("$real" +%s) + offset ))
args=() when='' given=false utc=false
while (($#)); do
  case $1 in
    -d | --date) given=true when=$2; shift 2 ;;
    --date=*) given=true when=${1#--date=}; shift ;;
    -d*) given=true when=${1#-d}; shift ;;
    -u | --utc | --universal) utc=true; args+=("$1"); shift ;;
    *) args+=("$1"); shift ;;
  esac
done
$utc && export TZ=UTC0
lower=${when,,}
if ! $given || [[ -z ${when//[[:space:]]/} || $lower == now ]]; then
  when="@$now"
elif [[ $when != @* ]]; then
  months='(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z.]*[[:space:]]+[0-9]'
  if [[ $lower =~ $months || $lower =~ [0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    # A calendar date: only its year, when it has none, is the clock's.
    [[ $lower =~ (^|[^0-9])[0-9]{4}($|[^0-9]) ]] || when="$when $("$real" -d "@$now" +%Y)"
  elif [[ $lower =~ [0-9]:[0-9]{2} || $lower =~ [0-9][[:space:]]*[ap][.]?m ]]; then
    when="$("$real" -d "@$now" +%F) $when"                  # a time of day: on the clock's day
  else
    when="$("$real" -d "@$now" '+%F %T %z') $when"          # relative ("+2 days", "tomorrow"): from the clock
  fi
fi
exec "$real" -d "$when" "${args[@]}"
FAKE
chmod +x "$test_root/clock/date"
export PATH="$test_root/clock:$PATH"
export HOME="$test_root/home"
export XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache" XDG_DATA_HOME="$HOME/.local/share"
# The tmux servers of the battery live in its own folder, so no tmux command can ever reach a real server.
export TMUX_TMPDIR="$test_root/tmux"
mkdir -p "$TMUX_TMPDIR"
# The processes of the battery, and only them: udarnik lists the claude processes of the machine (`ps`) and the
# children of a pane (`pgrep -P`), and both read /proc/<pid> of every process, the environment of a real worker
# included. Here they see the battery itself and the tmux servers of its own folder, with everything below them,
# found through /proc/<pid>/task/*/children of those processes alone.
mkdir -p "$test_root/procs"
printf '#!/usr/bin/env bash\nbattery=%q tmux_folder=%q\n' "$$" "$TMUX_TMPDIR/tmux-$(id -u)" >"$test_root/procs/battery-processes"
cat >>"$test_root/procs/battery-processes" <<'FAKE'
# The pid and command name of each process of the battery: below the battery and below its tmux servers.
children() { local list; for list in /proc/"$1"/task/*/children; do cat -- "$list" 2>/dev/null; done; }
below() {
  local comm child
  IFS= read -r comm 2>/dev/null <"/proc/$1/comm" || return 0
  printf '%s %s\n' "$1" "$comm"
  for child in $(children "$1"); do below "$child"; done
}
roots=("$battery")
for server in "$tmux_folder"/*; do
  [[ -S $server ]] || continue
  pid=$(tmux -S "$server" display-message -p '#{pid}' 2>/dev/null) && [[ $pid =~ ^[0-9]+$ ]] && roots+=("$pid")
done
for root in "${roots[@]}"; do below "$root"; done | sort -un
FAKE
cat >"$test_root/procs/ps" <<'FAKE'
#!/usr/bin/env bash
# ps of the battery: only the one listing udarnik asks for, of the processes of the battery.
[[ "$*" == "-eo pid=,comm=" ]] || { printf 'ps of the battery: only -eo pid=,comm=, not: %s\n' "$*" >&2; exit 2; }
"${0%/*}/battery-processes" | awk '{ printf "%7s %s\n", $1, $2 }'
FAKE
cat >"$test_root/procs/pgrep" <<'FAKE'
#!/usr/bin/env bash
# pgrep of the battery: only -P <pid>, the children of a process of the battery.
[[ $# == 2 && $1 == -P && $2 =~ ^[0-9]+$ ]] || { printf 'pgrep of the battery: only -P PID, not: %s\n' "$*" >&2; exit 2; }
found=1
for list in /proc/"$2"/task/*/children; do
  for child in $(cat -- "$list" 2>/dev/null); do printf '%s\n' "$child"; found=0; done
done
exit "$found"
FAKE
chmod +x "$test_root/procs/"*
export PATH="$test_root/procs:$PATH"
export UDARNIK_STATE="$test_root/state"
export UDARNIK_TMUX_SOCKET=$socket
# Never the real service: the unit is unique and systemctl/systemd-run are stubs.
export UDARNIK_UNIT="udarnik-test-$$"
export UDARNIK_CLONE_SCOPE=off
export UDARNIK_CLONE_WAIT_SECONDS=20
export UDARNIK_SHARED_DIR="$HOME/.claude-shared"
# No fleet unless a test sets one: the real fleet file (found through XDG_CONFIG_HOME too) and the real machines are
# never reached. The ssh command fails loudly if anything tries.
export XDG_CONFIG_HOME="$HOME/.config" UDARNIK_FLEET="$test_root/no-fleet.json" UDARNIK_SSH=false
project_root="$test_root/project"
mkdir -p "$HOME/.cache" "$project_root/sub" "$test_root/bin"
cd "$test_root"

cleanup() {
  local p
  tmux -L "$socket" kill-server 2>/dev/null || true
  tmux -L "$socket-peer" kill-server 2>/dev/null || true
  tmux -L "$socket-keep" kill-server 2>/dev/null || true
  # The children through the battery's pgrep: pkill would read /proc/<pid> of every process of the machine.
  for p in ${spawned:-}; do kill $(pgrep -P "$p") 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
  if [[ -n ${UDARNIK_TEST_KEEP:-} ]]; then printf 'kept %s\n' "$test_root" >&2; else rm -rf -- "$test_root"; fi
}
trap cleanup EXIT

passed=0
failed=0
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$1"; }
fail() { failed=$((failed + 1)); printf 'not ok - %s\n' "$1" >&2; }
assert_command() {
  local description=$1
  shift
  if "$@"; then pass "$description"; else fail "$description"; fi
}

account_a="$HOME/.claude"
account_b="$HOME/.claude-b"
account_c="$HOME/.claude-c"
mkdir -p "$account_a" "$account_b" "$account_c"
export UDARNIK_ACCOUNTS="$account_a:$account_b:$account_c"

# Stubs for the systemd user manager: nothing real is ever started, stopped or asked.
mkdir -p "$test_root/fake-systemd"
# systemd-run starts the udarnik service (a file says it is active). With --scope it runs the command in place, as
# systemd-run does, in a scope: the scope is active (a file of FAKE_SCOPES) and, when UDARNIK_PROC is set, the cgroup
# file of the process says so.
cat >"$test_root/fake-systemd/systemd-run" <<'FAKE'
#!/usr/bin/env bash
args=("$@") index=0 scope=false unit=''
while ((index < ${#args[@]})) && [[ ${args[$index]} == --* ]]; do
  [[ ${args[$index]} == --scope ]] && scope=true
  [[ ${args[$index]} == --unit=* ]] && unit=${args[$index]#--unit=}
  index=$((index + 1))
done
if ! $scope; then
  printf '%s\n' "$@" >"$FAKE_SYSTEMD_LOG"
  touch "$FAKE_SYSTEMD_ACTIVE"
  exit 0
fi
mkdir -p "$FAKE_SCOPES"
touch "$FAKE_SCOPES/$unit.scope"
printf '%s\n' "$unit" >>"$FAKE_SCOPES/started.log"
if [[ -n ${UDARNIK_PROC:-} ]]; then
  mkdir -p "$UDARNIK_PROC/$$"
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/%s.scope\n' "$unit" >"$UDARNIK_PROC/$$/cgroup"
fi
exec "${args[@]:$index}"
FAKE
cat >"$test_root/fake-systemd/systemctl" <<'FAKE'
#!/usr/bin/env bash
unit=${*: -1}
if [[ " $* " == *" is-active "* ]]; then
  if [[ $unit == *.scope ]]; then [[ -e $FAKE_SCOPES/$unit ]]; exit; fi
  [[ -e $FAKE_SYSTEMD_ACTIVE ]]; exit
fi
if [[ " $* " == *" stop "* ]]; then
  if [[ $unit == *.scope ]]; then
    mkdir -p "$FAKE_SCOPES"
    printf '%s\n' "$unit" >>"$FAKE_SCOPES/stopped.log"
    rm -f "$FAKE_SCOPES/$unit"
    exit 0
  fi
  rm -f "$FAKE_SYSTEMD_ACTIVE"; exit 0
fi
exit 0
FAKE
chmod +x "$test_root/fake-systemd/"*
export FAKE_SYSTEMD_LOG="$test_root/systemd.log" FAKE_SYSTEMD_ACTIVE="$test_root/systemd.active" FAKE_SCOPES="$test_root/fake-scopes"
export PATH="$test_root/fake-systemd:$PATH"

accounts() { source "$repo_root/lib/accounts.sh"; "$@"; }
udarnik() { "$repo_root/bin/udarnik" "$@"; }
export -f accounts udarnik
export repo_root

jq_check() { jq -e "$@" >/dev/null; }

usage_cache() { # <key> <weekly percent> <resets_at>
  jq -cn --argjson percent "$2" --arg reset "${3:-}" \
    '{limits:[{kind:"weekly_all", percent:$percent, resets_at:(if $reset == "" then null else $reset end)}]}' >"$HOME/.cache/claude-statusline-usage-$1.json"
  # The time of the reading is the time of the file: on the battery's clock.
  touch -d "@$(date +%s)" "$HOME/.cache/claude-statusline-usage-$1.json"
}

# ---------------------------------------------------------------- the battery itself

# A day ahead of the battery's clock, so the offset is never 0 here (a 0 would let date and udarnik ignore it).
assert_command 'the battery runs on its one clock: date reads it, and so does the builtin clock of udarnik' \
  bash -c 'export UDARNIK_CLOCK_OFFSET=$2; d=$(( $(date +%s) - $("$1" +%s) )); (( d >= $2 - 1 && d <= $2 + 1 )) &&
    UDARNIK_STATE="$3/clock-state" udarnik account clear --at "$(date +%s)" "$4" &&
    { UDARNIK_STATE="$3/clock-state" udarnik account clear --at "$(( $(date +%s) + 30 ))" "$4" 2>/dev/null; [[ $? == 2 ]]; } &&
    mkdir -p "$3/clock-state/accounts" && printf "%s\n" "$(( $(date +%s) - 60 ))" >"$3/clock-state/accounts/claude.out-until" &&
    ! UDARNIK_STATE="$3/clock-state" accounts account_marked_out "$4"' \
  _ "$real_date" "$((clock_offset + 86400))" "$test_root" "$account_a"
assert_command 'the battery sees its own processes only: ps and pgrep list it, never its caller nor pid 1' \
  bash -c 'l=$(ps -eo pid=,comm=) && grep -qE "^ *$1 " <<<"$l" && ! grep -qE "^ *($2|1) " <<<"$l" && pgrep -P "$1" | grep -qx "$$" && ! pgrep -X 2>/dev/null' \
  _ "$$" "$PPID"
assert_command 'the battery runs with none of the caller'"'"'s udarnik, agentic, XDG or tmux variables' \
  bash -c '[[ -z $(compgen -e | grep -E "^(UDARNIK_|AGENTIC_)" | grep -vxE "UDARNIK_(STATE|TMUX_SOCKET|UNIT|CLONE_SCOPE|CLONE_WAIT_SECONDS|SHARED_DIR|FLEET|SSH|ACCOUNTS|CLOCK_OFFSET)") ]] &&
    [[ -z ${TMUX:-} && -z ${BASH_ENV:-} && $XDG_STATE_HOME == "$1"/* && $XDG_CACHE_HOME == "$1"/* && $XDG_CONFIG_HOME == "$1"/* && $TMUX_TMPDIR == "$1"/* ]]' \
  _ "$test_root"

# ---------------------------------------------------------------- accounts.sh

future_text() { # <days ahead> -> error text whose reset is that many days ahead at 16:00 São Paulo time
  printf "You've hit your weekly limit · resets %s (America/Sao_Paulo)" \
    "$(LC_ALL=C TZ=America/Sao_Paulo date -d "+$1 days 16:00" '+%b %-d, %-I%P')"
}

expected=$(TZ=America/Sao_Paulo date -d '+3 days 16:00' +%s)
assert_command 'reset time is read from the real error text' \
  bash -c '[[ $(accounts reset_epoch_from_text "$1") == "$2" ]]' _ "$(future_text 3)" "$expected"

assert_command 'a date already past this year means next year' \
  bash -c 'e=$(accounts reset_epoch_from_text "$1") && (( e > $(date +%s) ))' _ "You've hit your weekly limit · resets Jan 2, 4am (America/Sao_Paulo)"

assert_command 'a bare time means the next occurrence' \
  bash -c 'e=$(accounts reset_epoch_from_text "$1") && (( e > $(date +%s) && e <= $(date +%s) + 90000 ))' _ "You've hit your session limit · resets 4am (America/Sao_Paulo)"

assert_command 'unreadable text is not a reset time' \
  bash -c '! accounts reset_epoch_from_text "usage limit reached" >/dev/null'

next_at() { # <time> [zone]: the next occurrence of that time of day (in that zone, else the system zone), as an epoch
  local epoch
  epoch=$(TZ=${2:-${TZ:-}} date -d "$1" +%s)
  (( epoch > $(date +%s) )) || epoch=$(TZ=${2:-${TZ:-}} date -d "$1 tomorrow" +%s)
  printf '%s\n' "$epoch"
}
saved_tz=${TZ-unset}
export TZ=Europe/Lisbon
assert_command 'a reset time without a zone is read in the system zone' \
  bash -c '[[ $(accounts reset_epoch_from_text "5-hour limit reached ∙ resets 3pm") == "$1" ]]' _ "$(next_at 15:00)"
assert_command 'a reset time followed by something that is not a zone name is not read' \
  bash -c '! accounts reset_epoch_from_text "You have hit your limit · resets 3pm (GMT+5:30)" >/dev/null'
assert_command 'a reset time inside a JSON string stops at its quote' \
  bash -c '[[ $(accounts reset_epoch_from_text "{\"result\":\"You have hit your limit · resets 3pm\",\"x\":\"(a)\"}") == "$1" ]]' _ "$(next_at 15:00)"
if [[ $saved_tz == unset ]]; then unset TZ; else export TZ=$saved_tz; fi

assert_command 'is_limit_text matches both limit messages and nothing else' \
  bash -c 'accounts is_limit_text "You'"'"'ve hit your weekly limit" && accounts is_limit_text "Claude AI USAGE LIMIT REACHED|1" && accounts is_limit_text "You have hit your session limit" && ! accounts is_limit_text "overloaded_error"'

assert_command 'account_env uses -u for ~/.claude and CLAUDE_CONFIG_DIR for the others' \
  bash -c '[[ $(accounts account_env "$1") == "env -u CLAUDE_CONFIG_DIR" && $(accounts account_env "$2") == "env CLAUDE_CONFIG_DIR=$2" ]]' _ "$account_a" "$account_b"

assert_command 'account_of_env follows CLAUDE_CONFIG_DIR and falls back to ~/.claude' \
  bash -c '[[ $(accounts account_of_env) == "$1" && $(CLAUDE_CONFIG_DIR= accounts account_of_env) == "$1" && $(CLAUDE_CONFIG_DIR="$2/" accounts account_of_env) == "$2" ]]' _ "$account_a" "$account_b"

# The shared folder is never an account, wherever it is.
discovery_home="$test_root/discovery"
mkdir -p "$discovery_home/.claude" "$discovery_home/.claude-x" "$discovery_home/.claude-shared" "$discovery_home/elsewhere"
for directory in .claude .claude-x .claude-shared elsewhere; do : >"$discovery_home/$directory/.credentials.json"; done
assert_command 'account discovery lists ~/.claude and ~/.claude-* with credentials and never the shared folder' \
  bash -c '[[ $(env -u UDARNIK_ACCOUNTS HOME="$1" UDARNIK_SHARED_DIR="$1/.claude-shared" bash -c "accounts accounts_list" | sort | tr "\n" " ") == "$1/.claude $1/.claude-x " ]] && [[ $(env -u UDARNIK_ACCOUNTS HOME="$1" UDARNIK_SHARED_DIR="$1/.claude-x" bash -c "accounts accounts_list" | sort | tr "\n" " ") == "$1/.claude " ]]' _ "$discovery_home"

# mark_out: text, then usage file, then one hour.
accounts account_mark_out "$account_a" "$(future_text 3)" >/dev/null
assert_command 'mark_out stores the reset read from the text' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude.out-until") == "$1" ]] && ! accounts account_available "$2"' _ "$expected" "$account_a"

cache_reset=$(date -u -d '+2 days' '+%Y-%m-%dT%H:%M:%S+00:00')
usage_cache claude-b 40 "$cache_reset"
accounts account_mark_out "$account_b" "unreadable" >/dev/null
assert_command 'mark_out of a limit without a reset time is one hour, never the weekly reset of the usage file' \
  bash -c 'v=$(cat "$UDARNIK_STATE/accounts/claude-b.out-until"); now=$(date +%s); (( v >= now + 3590 && v <= now + 3610 ))'

accounts account_mark_out "$account_c" "unreadable" >/dev/null
assert_command 'mark_out without a usage file falls back to one hour from now' \
  bash -c 'v=$(cat "$UDARNIK_STATE/accounts/claude-c.out-until"); now=$(date +%s); (( v >= now + 3590 && v <= now + 3610 ))'

hint=$(( $(date +%s) + 5000 ))
accounts account_mark_out "$account_c" "You've hit your limit" "$hint" >/dev/null
assert_command 'mark_out of a text without a reset time takes the resetsAt of the history before the hour' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == "$1" ]]' _ "$hint"
accounts account_mark_out "$account_c" "$(future_text 3)" "$hint" >/dev/null
assert_command 'mark_out prefers the reset time of the text to the resetsAt of the history' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == "$1" ]]' _ "$expected"
assert_command 'mark_out records when it learned the out-until, and that it was here' \
  bash -c 'read -r at from <"$UDARNIK_STATE/accounts/claude-c.out-news"; now=$(date +%s); (( at >= now - 5 && at <= now )) && [[ -z $from ]]'

# Learning from other machines: a newer news of the same machine wins, even earlier; between machines the later epoch
# wins; a news without a time only moves it later; a past one is gone.
learn_c() { accounts account_learn_out "$account_c" "$@"; }
rm -f "$UDARNIK_STATE"/accounts/claude-c.*
now_s=$(date +%s)
learn_c $((now_s + 7200)) $((now_s - 100)) kepler
assert_command 'learn stores the epoch with the time and the machine of the news' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == $(( $1 + 7200 )) && $(cat "$UDARNIK_STATE/accounts/claude-c.out-news") == "$(( $1 - 100 )) kepler" ]]' _ "$now_s"
learn_c $((now_s + 3600)) $((now_s - 50)) kepler || true
assert_command 'learn: a newer news of the same machine moves the epoch earlier' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == $(( $1 + 3600 )) ]]' _ "$now_s"
learn_c $((now_s + 9000)) $((now_s - 80)) kepler || true
assert_command 'learn: an older news changes nothing' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == $(( $1 + 3600 )) ]]' _ "$now_s"
learn_c $((now_s + 1800)) $((now_s - 10)) box || true
assert_command 'learn: a newer news of another machine with an earlier epoch never moves the epoch earlier' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == $(( $1 + 3600 )) && $(cat "$UDARNIK_STATE/accounts/claude-c.out-news") == "$(( $1 - 50 )) kepler" ]]' _ "$now_s"
learn_c $((now_s + 5400)) $((now_s - 900)) box || true
assert_command 'learn: between machines the later epoch wins, whatever the time of the news (their clocks differ)' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == $(( $1 + 5400 )) && $(cat "$UDARNIK_STATE/accounts/claude-c.out-news") == "$(( $1 - 900 )) box" ]]' _ "$now_s"
learn_c $((now_s + 1000)) || true
assert_command 'learn: a news without a time (an older udarnik) never moves the epoch earlier' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == $(( $1 + 5400 )) ]]' _ "$now_s"

# A guess here (no reset time anywhere) never frees an account another machine read is out longer, and is not told.
rm -f "$UDARNIK_STATE"/accounts/claude-c.*
learn_c $((now_s + 5 * 86400)) $((now_s - 60)) kepler
assert_command 'mark_out: a guess of one hour never moves earlier an out-until learned from a reset text, and is not news' \
  bash -c 'v=$(accounts account_mark_out "$1" "$(cat "$2/tests/fixtures/limit-envelope-no-reset.json")") && exit 1
    [[ $v == $(( $3 + 5 * 86400 )) && $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == "$v" && $(cat "$UDARNIK_STATE/accounts/claude-c.out-news") == "$(( $3 - 60 )) kepler" ]]' \
  _ "$account_c" "$repo_root" "$now_s"
accounts account_mark_out "$account_c" "$(future_text 3)" >/dev/null
assert_command 'mark_out: a reset read from the text replaces a later out-until' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == "$1" ]] && read -r at from <"$UDARNIK_STATE/accounts/claude-c.out-news" && [[ -z $from ]]' _ "$expected"
rm -f "$UDARNIK_STATE"/accounts/claude-c.*
learn_c $((now_s + 600)) $((now_s - 60)) kepler
assert_command 'mark_out: a guess later than the out-until known replaces it and is news' \
  bash -c 'v=$(accounts account_mark_out "$1" "unreadable") && (( v >= $2 + 3590 )) && [[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == "$v" ]]' _ "$account_c" "$now_s"
printf '%s\n' $((now_s - 5)) >"$UDARNIK_STATE/accounts/claude-c.out-until"
learn_c $((now_s + 600)) $((now_s - 3600)) kepler || true
assert_command 'learn: an out-until that is over is gone, so even an older news counts again' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-c.out-until") == $(( $1 + 600 )) ]]' _ "$now_s"

# The service's log lines go to its journal on stderr: a function whose output is read as a value (the epoch of a
# limit, the id of a clone) logs too, and a line on stdout became part of the value.
assert_command 'the service log goes to stderr, never into a value read from a function (the epoch of a limit)' \
  bash -c 'UDARNIK_LOG_JOURNAL=1; export UDARNIK_STATE=$1/journal-state; source "$2/lib/accounts.sh"
    v=$(account_mark_out "$3" "unreadable" 2>"$1/journal.err") && [[ $v =~ ^[0-9]+$ ]] && grep -q " is out of quota until " "$1/journal.err"' \
  _ "$test_root" "$repo_root" "$account_c"
assert_command 'a log switch inherited from an older service (UDARNIK_LOG_STDOUT=1) puts nothing on the stdout of account limit' \
  bash -c 'out=$(UDARNIK_LOG_STDOUT=1 UDARNIK_STATE="$1/journal-state" udarnik account limit "$2" <"$3/tests/fixtures/limit-envelope.json" 2>/dev/null) && [[ $out == "$4" || $out == "$5" ]]' \
  _ "$test_root" "$account_c" "$repo_root" "$account_a" "$account_b"
printf '%s\n' $((now_s - 5)) >"$UDARNIK_STATE/accounts/claude-c.out-until"
accounts accounts_forget_expired
assert_command 'an out-until that is over is removed with its news' \
  bash -c '[[ ! -e $UDARNIK_STATE/accounts/claude-c.out-until && ! -e $UDARNIK_STATE/accounts/claude-c.out-news ]]'

rm -f "$UDARNIK_STATE"/accounts/*.out-until
usage_cache claude 70 ""
usage_cache claude-b 20 ""
rm -f "$HOME/.cache/claude-statusline-usage-claude-c.json"
assert_command 'pick takes the lowest weekly usage and puts unknown usage last' \
  bash -c '[[ $(accounts account_pick) == "$1" ]]' _ "$account_b"
assert_command 'pick skips the excluded accounts' \
  bash -c '[[ $(accounts account_pick "$1") == "$2" ]]' _ "$account_b" "$account_a"
accounts account_mark_out "$account_b" "$(future_text 2)" >/dev/null
assert_command 'pick skips accounts that are out' \
  bash -c '[[ $(accounts account_pick) == "$1" ]]' _ "$account_a"
accounts account_mark_out "$account_a" "$(future_text 2)" >/dev/null
assert_command 'pick falls to the account with unknown usage when it is the only one left' \
  bash -c '[[ $(accounts account_pick) == "$1" ]]' _ "$account_c"
accounts account_mark_out "$account_c" "$(future_text 2)" >/dev/null
assert_command 'pick fails when every account is out' \
  bash -c '! accounts account_pick >/dev/null'
rm -f "$UDARNIK_STATE"/accounts/*.out-until

# The usage file is only ever read, from the template.
mkdir -p "$test_root/usage"
jq -cn '{limits:[{kind:"weekly_all", percent:5, resets_at:null}]}' >"$test_root/usage/claude-b.json"
assert_command 'UDARNIK_USAGE_FILE replaces {key} with the account key and the default path is not read' \
  bash -c '[[ $(UDARNIK_USAGE_FILE="$1/usage/{key}.json" accounts account_weekly_percent "$2") == 5 && -z $(UDARNIK_USAGE_FILE="$1/usage/{key}.json" accounts account_weekly_percent "$3") ]]' _ "$test_root" "$account_b" "$account_a"

# ensure_shared_links
shared="$HOME/.claude-shared"
mkdir -p "$shared/projects/-p-one/memory" "$shared/skills/skill-one" "$shared/skills/skill-two"
printf 'm\n' >"$shared/projects/-p-one/memory/MEMORY.md"
mkdir -p "$account_a/skills/skill-two" "$account_b/projects/-p-one/memory"
printf 'mine\n' >"$account_a/skills/skill-two/own.txt"
printf 'mine\n' >"$account_b/projects/-p-one/memory/own.md"
accounts ensure_shared_links
accounts ensure_shared_links
assert_command 'shared memory and skills become symlinks in every account' \
  bash -c '[[ $(readlink "$1/projects/-p-one/memory") == "$4/projects/-p-one/memory" && $(readlink "$1/skills/skill-one") == "$4/skills/skill-one" && $(readlink "$2/skills/skill-two") == "$4/skills/skill-two" && $(readlink "$3/projects/-p-one/memory") == "$4/projects/-p-one/memory" ]]' _ "$account_a" "$account_b" "$account_c" "$shared"
assert_command 'a real folder is never replaced' \
  bash -c '[[ ! -L "$1/skills/skill-two" && -f "$1/skills/skill-two/own.txt" && ! -L "$2/projects/-p-one/memory" && -f "$2/projects/-p-one/memory/own.md" ]]' _ "$account_a" "$account_b"
assert_command 'a skipped real folder is logged once, not on every run' \
  bash -c '[[ $(grep -c "is a real folder" "$UDARNIK_STATE/udarnik.log") == 2 ]]'
assert_command 'ensure_shared_links is idempotent' \
  bash -c 'before=$(wc -l <"$UDARNIK_STATE/udarnik.log"); accounts ensure_shared_links; [[ $(wc -l <"$UDARNIK_STATE/udarnik.log") == "$before" ]]'
assert_command 'ensure_shared_links does nothing when the shared folder does not exist' \
  bash -c 'before=$(wc -l <"$UDARNIK_STATE/udarnik.log"); UDARNIK_SHARED_DIR="$1/none" accounts ensure_shared_links; [[ $(wc -l <"$UDARNIK_STATE/udarnik.log") == "$before" && ! -e "$1/none" ]]' _ "$test_root"
rm -rf "$shared"
rm -f "$account_a/skills/skill-one" "$account_b/skills/skill-one" "$account_c/skills/skill-one" "$account_b/skills/skill-two" "$account_c/skills/skill-two"

# ---------------------------------------------------------------- udarnik account (the hook for runners)

mkdir -p "$UDARNIK_STATE"
rm -f "$UDARNIK_STATE/enabled" "$UDARNIK_STATE/runners"
assert_command 'account enabled is never on by default, whatever the number of accounts' \
  bash -c '! udarnik account enabled'
assert_command 'account enabled follows the runners switch only, not the takeover switch' \
  bash -c 'udarnik runners on >/dev/null && udarnik account enabled && [[ ! -e $UDARNIK_STATE/enabled ]] && : >"$UDARNIK_STATE/enabled" && udarnik runners off >/dev/null && ! udarnik account enabled && [[ -e $UDARNIK_STATE/enabled ]] && [[ $(udarnik runners status) == "Account switching for runners: off" ]]'
rm -f "$UDARNIK_STATE/runners"
assert_command 'migration: a takeover switch from before the runners file counts as the runners on' \
  bash -c 'udarnik account enabled && [[ $(udarnik runners status) == "Account switching for runners: on" ]]'
assert_command 'migration: runners off turns them off even with that switch' \
  bash -c 'udarnik runners off >/dev/null && ! udarnik account enabled && [[ -e $UDARNIK_STATE/enabled ]]'
rm -f "$UDARNIK_STATE/runners"
assert_command 'migration: stop keeps the runners on and says how to turn them off' \
  bash -c 'out=$(udarnik stop) && [[ ! -e $UDARNIK_STATE/enabled ]] && udarnik account enabled && grep -qx "Account switching for runners stays on; to turn it off: udarnik runners off" <<<"$out"'
: >"$UDARNIK_STATE/enabled"
rm -f "$UDARNIK_STATE/runners"
assert_command 'migration: stop --all turns the runners off too' \
  bash -c 'udarnik stop --all >/dev/null && ! udarnik account enabled && [[ ! -e $UDARNIK_STATE/enabled ]]'
assert_command 'runners refuses an unknown subcommand' \
  bash -c '! udarnik runners maybe 2>/dev/null'
udarnik runners on >/dev/null
usage_cache claude 70 ""
usage_cache claude-b 20 ""
assert_command 'account current is the caller account when it is available' \
  bash -c '[[ $(udarnik account current) == "$1" && $(CLAUDE_CONFIG_DIR="$2" udarnik account current) == "$2" ]]' _ "$account_a" "$account_b"
accounts account_mark_out "$account_a" "$(future_text 1)" >/dev/null
assert_command 'account current moves a caller whose account is out to the best available one' \
  bash -c '[[ $(udarnik account current) == "$1" ]]' _ "$account_b"
assert_command 'account current keeps the caller account when the runners switch is off' \
  bash -c 'udarnik runners off >/dev/null; r=0; [[ $(udarnik account current) == "$1" ]] || r=1; udarnik runners on >/dev/null; exit $r' _ "$account_a"

# The preference order of a kind of caller decides where to go, never whether to leave the caller's account.
usage_cache claude-c 90 ""
assert_command 'order: without a file or a variable --kind changes nothing' \
  bash -c '[[ $(udarnik account current --kind worker) == "$1" && $(udarnik account pick --kind worker) == "$1" && $(udarnik account pick --kind interactive) == "$1" ]]' _ "$account_b"
printf 'claude-c\n# the owner choice\nclaude-b\n' >"$UDARNIK_STATE/order.worker"
assert_command 'order: the order file of the kind comes first, before the weekly usage' \
  bash -c '[[ $(udarnik account current --kind worker) == "$1" && $(udarnik account pick --kind worker) == "$1" && $(udarnik account pick --kind interactive) == "$2" && $(udarnik account pick) == "$2" ]]' _ "$account_c" "$account_b"
assert_command 'order: the caller keeps its account while it has quota' \
  bash -c '[[ $(CLAUDE_CONFIG_DIR="$1" udarnik account current --kind worker) == "$1" ]]' _ "$account_b"
assert_command 'order: UDARNIK_ORDER_<KIND> wins over the file, and accounts outside it come after by weekly usage' \
  bash -c '[[ $(UDARNIK_ORDER_WORKER=claude-b udarnik account pick --kind worker) == "$1" && $(UDARNIK_ORDER_INTERACTIVE="claude-x, $3" udarnik account pick --kind interactive) == "$3" && $(UDARNIK_ORDER_WORKER=claude-x udarnik account pick --kind worker) == "$1" ]]' _ "$account_b" "$account_a" "$account_c"
assert_command 'order: an account of the order that is out is skipped' \
  bash -c 'printf "%s\n" $(( $(date +%s) + 3600 )) >"$UDARNIK_STATE/accounts/claude-c.out-until"; r=0; [[ $(udarnik account pick --kind worker) == "$2" ]] || r=1; rm -f "$UDARNIK_STATE/accounts/claude-c.out-until"; exit $r' _ "$account_c" "$account_b"
assert_command 'order: an unknown kind is refused' \
  bash -c '! udarnik account pick --kind batch 2>/dev/null'
rm -f "$UDARNIK_STATE/order.worker" "$HOME/.cache/claude-statusline-usage-claude-c.json"
assert_command 'account env prints the env prefix for ~/.claude and for the others' \
  bash -c '[[ $(udarnik account env "$1") == "env -u CLAUDE_CONFIG_DIR" && $(udarnik account env "$2") == "env CLAUDE_CONFIG_DIR=$2" ]]' _ "$account_a" "$account_b"
assert_command 'account pick prints the available account with the lowest usage' \
  bash -c '[[ $(udarnik account pick) == "$1" ]]' _ "$account_b"
rm -f "$UDARNIK_STATE"/accounts/*.out-until

limit_rc() { # <account> <stdin text> -> exit status; the stdout goes to limit.out
  local code=0
  printf '%s' "$2" | udarnik account limit "$1" >"$test_root/limit.out" 2>/dev/null || code=$?
  printf '%s' "$code"
}
rc_none=$(limit_rc "$account_a" 'overloaded_error')
assert_command 'account limit exits 1 and prints nothing for a text that is not a usage-limit message' \
  bash -c '[[ $1 == 1 && ! -s "$2/limit.out" ]] && accounts account_available "$3"' _ "$rc_none" "$test_root" "$account_a"
rc_first=$(limit_rc "$account_a" "$(future_text 2)")
assert_command 'account limit marks the account out until the parsed reset and prints the best other account' \
  bash -c '[[ $1 == 0 && $(cat "$2/limit.out") == "$3" && $(accounts account_out_until "$4") == "$5" ]]' _ "$rc_first" "$test_root" "$account_b" "$account_a" "$(TZ=America/Sao_Paulo date -d '+2 days 16:00' +%s)"
rc_second=$(limit_rc "$account_b" "$(future_text 1)")
assert_command 'account limit falls to the account with unknown usage' \
  bash -c '[[ $1 == 0 && $(cat "$2/limit.out") == "$3" ]]' _ "$rc_second" "$test_root" "$account_c"
rc_third=$(limit_rc "$account_c" "$(future_text 3)")
assert_command 'account limit exits 75 when every account is out' \
  bash -c '[[ $1 == 75 && ! -s "$2/limit.out" ]]' _ "$rc_third" "$test_root"
assert_command 'account next is the epoch at which the first account is available again' \
  bash -c '[[ $(udarnik account next) == "$(accounts account_out_until "$1")" ]]' _ "$account_b"
rm -f "$UDARNIK_STATE/accounts/claude-b.out-until"
assert_command 'account next is now when an account is already available' \
  bash -c 'n=$(udarnik account next); now=$(date +%s); (( n >= now - 2 && n <= now + 2 ))'
rm -f "$UDARNIK_STATE"/accounts/*.out-until

# The JSON envelope of `claude --print --output-format json` (a made-up fixture until a real one is captured).
rc_envelope=$(limit_rc "$account_a" "$(cat "$repo_root/tests/fixtures/limit-envelope.json")")
assert_command 'account limit reads the reset time inside the JSON envelope of a headless call' \
  bash -c '[[ $1 == 0 && $(cat "$2/limit.out") == "$3" && $(accounts account_out_until "$4") == "$5" ]]' _ "$rc_envelope" "$test_root" "$account_b" "$account_a" "$(next_at 16:00 America/Sao_Paulo)"
rm -f "$UDARNIK_STATE"/accounts/*.out-until
usage_cache claude 70 "$(date -u -d '+5 days' '+%Y-%m-%dT%H:%M:%S+00:00')"
rc_envelope=$(limit_rc "$account_a" "$(cat "$repo_root/tests/fixtures/limit-envelope-no-reset.json")")
assert_command 'account limit of an envelope without a reset time marks the account out for one hour' \
  bash -c 'v=$(accounts account_out_until "$2"); now=$(date +%s); [[ $1 == 0 ]] && (( v >= now + 3590 && v <= now + 3610 ))' _ "$rc_envelope" "$account_a"
rm -f "$UDARNIK_STATE"/accounts/*.out-until
rc_kind=$(printf '%s' "$(future_text 1)" | UDARNIK_ORDER_WORKER=claude-c udarnik account limit --kind worker "$account_a" 2>/dev/null; printf ' %s' $?)
assert_command 'account limit --kind goes to the next account of the order of that kind' \
  bash -c '[[ $1 == "$2"$'"'"'\n'"'"'" 0" ]]' _ "$rc_kind" "$account_c"
rm -f "$UDARNIK_STATE"/accounts/*.out-until

# account list: what every account is, from files only.
: >"$account_a/.credentials.json"
printf '%s\n' '{"hasCompletedOnboarding":true,"oauthAccount":{"accountUuid":"user-b","organizationUuid":"org-b"}}' >"$account_b/.claude.json"
printf '%s\n' "$(( $(date +%s) + 3600 ))" >"$UDARNIK_STATE/accounts/claude-c.out-until"
udarnik account list --json >"$test_root/list.json"
assert_command 'account list --json: one object per account with its key, folder, identity, login and onboarding' \
  jq_check --arg a "$account_a" --arg b "$account_b" '[.[] | [.key, .path, .identity, .logged_in, .onboarded]] == [["claude", $a, null, true, false], ["claude-b", $b, "user-b/org-b", false, true], ["claude-c", ($a + "-c"), null, false, false]]' "$test_root/list.json"
assert_command 'account list --json: availability, out-until, weekly usage and the age of that data' \
  jq_check --arg here "$(uname -n | cut -d. -f1)" '[.[] | [.available, (.out_until != null), .weekly_percent, (.weekly_age_seconds | type), .weekly_from]] == [[true, false, 70, "number", $here], [true, false, 20, "number", $here], [false, true, 90, "number", $here]]' "$test_root/list.json"
assert_command 'the weekly usage read here stays known after the usage file is gone' \
  bash -c '[[ $(jq -r .percent "$UDARNIK_STATE/accounts/claude-c.weekly") == 90 && ! -e $HOME/.cache/claude-statusline-usage-claude-c.json ]]'
assert_command 'account list prints one line per account' \
  bash -c 'out=$(udarnik account list); [[ $(wc -l <<<"$out") == 3 ]] && grep -q "^claude-b  $1  user-b/org-b  not logged in  onboarded  available  weekly 20% (" <<<"$out" && grep -q "^claude-c  .*  out until " <<<"$out"' _ "$account_b"
rm -f "$account_a/.credentials.json" "$account_b/.claude.json" "$UDARNIK_STATE"/accounts/*.out-until "$UDARNIK_STATE/enabled" "$UDARNIK_STATE/runners" "$UDARNIK_STATE/udarnik.log"

# account wait: the wait of a runner whose every account is out, seen by status and ended by the switch.
eventually() { local i; for ((i = 0; i < 50; i++)); do "$@" && return 0; sleep 0.2; done; return 1; }
all_out() { local account; for account in "$account_a" "$account_b" "$account_c"; do accounts account_mark_out "$account" "$(future_text 1)" >/dev/null; done; }
waiting_pids() { udarnik status --json | jq -r '[.waiting[].pid] | join(" ")'; }
wait_registered() { [[ " $(waiting_pids) " == *" $1 "* ]]; }
wait_gone() { ! kill -0 "$1" 2>/dev/null; }
mkdir -p "$UDARNIK_STATE"
all_out
assert_command 'account wait exits 1 at once, prints nothing and registers nothing when the runners switch is off' \
  bash -c '! udarnik account enabled; rc=0; out=$(UDARNIK_WAIT_SLICE=0.2 udarnik account wait --label X 2>&1) || rc=$?; [[ $rc == 1 && -z $out && -z $(ls "$UDARNIK_STATE/waits" 2>/dev/null) ]]'
udarnik runners on >/dev/null
# The file of a wait that was killed before it could remove it.
# (A process of the battery that is gone, so that no /proc entry of a process outside it is ever read.)
mkdir -p "$UDARNIK_STATE/waits"
sleep 0.1 & dead_wait=$!
wait "$dead_wait"
printf '{"pid":%s,"start":"1","label":"dead","cwd":"/","since":1,"until":2}\n' "$dead_wait" >"$UDARNIK_STATE/waits/$dead_wait.json"
UDARNIK_WAIT_SLICE=0.3 "$repo_root/bin/udarnik" account wait --label wait-one >"$test_root/wait-one.out" 2>&1 & wait_one=$!
spawned="${spawned:-} $wait_one"
registered_in_status() {
  udarnik status --json | jq -e --argjson pid "$wait_one" --arg cwd "$test_root" '[.waiting[] | select(.pid == $pid)
    | .label == "wait-one" and .cwd == $cwd and (.since | type) == "number" and .until > .since
      and (.until_local | test("^[0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}$"))] == [true]' >/dev/null
}
assert_command 'account wait with every account out is registered and shown by status --json' eventually registered_in_status
assert_command 'account wait is printed on the board, after the workers' \
  bash -c 'out=$(udarnik status); grep -qE "^  pid $1  until [0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}  wait-one  $2$" <<<"$out" &&
    [[ $(grep -n "^Workers (headless claude)" <<<"$out" | cut -d: -f1) -lt $(grep -n "^Runners waiting for quota" <<<"$out" | cut -d: -f1) ]]' _ "$wait_one" "$test_root"
assert_command 'account wait drops the file of a wait whose process is gone, and logs when it starts' \
  bash -c '[[ ! -e $UDARNIK_STATE/waits/$1.json ]] && grep -q "runner wait-one waits for quota until [0-9][0-9]/[0-9][0-9] [0-9][0-9]:[0-9][0-9]$" "$UDARNIK_STATE/udarnik.log"' _ "$dead_wait"
udarnik runners off >/dev/null
eventually wait_gone "$wait_one" || true
rc=0; wait "$wait_one" || rc=$?
assert_command 'account wait exits 1 within a few slices once the runners switch is off, prints nothing and its record is gone' \
  bash -c '[[ $1 == 1 && ! -e $UDARNIK_STATE/waits/$2.json && ! -s $3 ]] && grep -q "runner wait-one stops waiting: the runners switch is off" "$UDARNIK_STATE/udarnik.log"' _ "$rc" "$wait_one" "$test_root/wait-one.out"
# An account that is back, cleared by a call that worked, ends the wait with 0.
udarnik runners on >/dev/null
UDARNIK_WAIT_SLICE=0.3 "$repo_root/bin/udarnik" account wait >"$test_root/wait-two.out" 2>&1 & wait_two=$!
spawned="${spawned:-} $wait_two"
eventually wait_registered "$wait_two" || true
udarnik account clear "$account_b"
eventually wait_gone "$wait_two" || true
rc=0; wait "$wait_two" || rc=$?
assert_command 'account wait exits 0 once an account is cleared, prints nothing and its record is gone' \
  bash -c '[[ $1 == 0 && ! -e $UDARNIK_STATE/waits/$2.json && ! -s $3 ]] && grep -q "runner $2 stops waiting: an account is back" "$UDARNIK_STATE/udarnik.log"' _ "$rc" "$wait_two" "$test_root/wait-two.out"
# The out-until that passes does the same.
for account in "$account_a" "$account_b" "$account_c"; do
  key=$(basename "$account"); printf '%s\n' "$(( $(date +%s) + 2 ))" >"$UDARNIK_STATE/accounts/${key#.}.out-until"
done
UDARNIK_WAIT_SLICE=0.3 "$repo_root/bin/udarnik" account wait --label wait-three >/dev/null 2>&1 & wait_three=$!
spawned="${spawned:-} $wait_three"
eventually wait_gone "$wait_three" || true
rc=0; wait "$wait_three" || rc=$?
assert_command 'account wait exits 0 when the out-until passes' \
  bash -c '[[ $1 == 0 && ! -e $UDARNIK_STATE/waits/$2.json ]]' _ "$rc" "$wait_three"
rm -f "$UDARNIK_STATE"/accounts/*.out-* "$UDARNIK_STATE/runners" "$UDARNIK_STATE/udarnik.log"

# ---------------------------------------------------------------- bin/udarnik, one loop with everything fake

# Claude Code was opened interactively in every test account (a clone never starts in one where it was not).
onboarded='{"hasCompletedOnboarding":true}'
printf '%s\n' "$onboarded" >"$HOME/.claude.json"
printf '%s\n' "$onboarded" >"$account_b/.claude.json"
printf '%s\n' "$onboarded" >"$account_c/.claude.json"

# The fake claude records its argv and environment, forks the history like --fork-session, registers its session and sleeps.
cat >"$test_root/bin/claude" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
calls="$FAKE_CLAUDE_CALLS"
mkdir -p "$calls"
number=$(( $(find "$calls" -name '*.argv' | wc -l) + 1 ))
printf '%s\n' "$@" >"$calls/$number.argv"
printf '%s\n' "${CLAUDE_CONFIG_DIR-UNSET}" >"$calls/$number.config"
printf '%s\n' "$PWD" >"$calls/$number.cwd"
printf '%s %s\n' "${UDARNIK_LOG_JOURNAL-UNSET}" "${UDARNIK_LOG_STDOUT-UNSET}" >"$calls/$number.log-switches"
resume='' fork=false
while (($#)); do
  if [[ $1 == --resume ]]; then resume=$2; fi
  if [[ $1 == --fork-session ]]; then fork=true; fi
  shift
done
# FAKE_TRUST_FILE: first the question about the folder, "No, exit" selected; Down moves to "Yes", Enter confirms.
if [[ -n ${FAKE_TRUST_FILE:-} && ! -e $FAKE_TRUST_FILE ]]; then
  draw() { clear; printf ' Accessing workspace:\n %s\n %s No, exit\n %s Yes, I trust this folder\n Enter to confirm · Esc to cancel\n' "$PWD" "$1" "$2"; }
  draw '>' ' '
  selected=no
  while IFS= read -rsn1 key; do
    if [[ $key == $'\e' ]]; then
      read -rsn2 rest
      if [[ $rest == '[B' || $rest == OB ]]; then selected=yes; draw ' ' '>'; fi
      continue
    fi
    if [[ -z $key ]]; then
      [[ $selected == yes ]] || exit 1
      touch "$FAKE_TRUST_FILE"
      break
    fi
  done
  clear
fi
# A fork is a new session with a copy of the history; a plain --resume is the same session.
new=$resume
$fork && new=$(python3 -c 'import uuid; print(uuid.uuid4())')
slug=$(sed -E 's/[^A-Za-z0-9]/-/g' <<<"$PWD")
mkdir -p "$config/projects/$slug" "$config/sessions"
$fork && cp "$config/projects/$slug/$resume.jsonl" "$config/projects/$slug/$new.jsonl"
printf '%s\n' "$new" >"$calls/$number.session"
jq -cn --argjson pid "$$" --arg id "$new" --arg cwd "$PWD" --argjson started "$(( $(date +%s) * 1000 ))" \
  '{pid:$pid, sessionId:$id, cwd:$cwd, kind:"interactive", startedAt:$started, updatedAt:$started}' >"$config/sessions/$$.json"
exec sleep 300
FAKE
chmod +x "$test_root/bin/claude"
export FAKE_CLAUDE_CALLS="$test_root/calls"
export PATH="$test_root/bin:$PATH"

iso_now() { date -u '+%Y-%m-%dT%H:%M:%S.000Z'; }
slug_of() { sed -E 's/[^A-Za-z0-9]/-/g' <<<"$1"; }

# new_session <account> <id> <cwd> <last entry: ok|limit|stale> [entrypoint]: a live "interactive session" (a sleep) with
# a history; its registry file has the entrypoint when one is given (none: as older Claude Code did).
new_session() {
  local account=$1 id=$2 cwd=$3 kind=$4 entrypoint=${5:-} slug history started stamp
  slug=$(slug_of "$cwd")
  history="$account/projects/$slug/$id.jsonl"
  mkdir -p "$account/sessions" "$account/projects/$slug/$id/subagents" "$cwd"
  sleep 300 &
  local pid=$!
  spawned="${spawned:-} $pid"
  started=$(( ($(date +%s) - 120) * 1000 ))
  jq -cn --argjson pid "$pid" --arg id "$id" --arg cwd "$cwd" --argjson started "$started" --arg entrypoint "$entrypoint" \
    '{pid:$pid, sessionId:$id, cwd:$cwd, kind:"interactive", startedAt:$started, updatedAt:$started}
      + (if $entrypoint == "" then {} else {entrypoint:$entrypoint} end)' >"$account/sessions/$pid.json"
  printf 'subagent transcript\n' >"$account/projects/$slug/$id/subagents/agent-1.jsonl"
  stamp=$(iso_now)
  {
    jq -cn --arg id "$id" '{type:"permission-mode", permissionMode:"bypassPermissions", sessionId:$id}'
    jq -cn --arg id "$id" --arg ts "$stamp" '{type:"user", sessionId:$id, timestamp:$ts, origin:{kind:"human"}, message:{role:"user", content:"please fix the thing in the checkout"}}'
    jq -cn --arg id "$id" --arg ts "$stamp" '{type:"assistant", sessionId:$id, timestamp:$ts, effort:"xhigh", message:{model:"claude-opus-5-5", role:"assistant", content:[{type:"text", text:"working"}]}}'
    case $kind in
      limit) jq -cn --arg id "$id" --arg ts "$stamp" --arg text "$(future_text 3)" --argjson resets "$expected" \
        '{type:"assistant", sessionId:$id, timestamp:$ts, isApiErrorMessage:true, error:"rate_limit", quotaLimits:{resetsAt:$resets}, message:{model:"<synthetic>", role:"assistant", content:[{type:"text", text:$text}]}}' ;;
      stale) jq -cn --arg id "$id" --arg ts "$stamp" --argjson resets "$(( $(date +%s) - 60 ))" \
        '{type:"assistant", sessionId:$id, timestamp:$ts, isApiErrorMessage:true, error:"rate_limit", quotaLimits:{resetsAt:$resets}, message:{model:"<synthetic>", role:"assistant", content:[{type:"text", text:"You'"'"'ve hit your weekly limit · resets Oct 7, 2am (America/Sao_Paulo)"}]}}' ;;
    esac
    jq -cn --arg id "$id" '{type:"last-prompt", sessionId:$id}'
  } >"$history"
  LAST_PID=$pid
}

id_limit=11111111-aaaa-4aaa-8aaa-111111111111
id_ok=22222222-bbbb-4bbb-8bbb-222222222222
id_stale=33333333-cccc-4ccc-8ccc-333333333333
id_outside=44444444-dddd-4ddd-8ddd-444444444444
new_session "$account_a" "$id_limit" "$project_root/sub" limit; pid_limit=$LAST_PID
new_session "$account_a" "$id_ok" "$project_root" ok; pid_ok=$LAST_PID
new_session "$account_a" "$id_stale" "$project_root" stale; pid_stale=$LAST_PID
new_session "$account_a" "$id_outside" "$test_root/elsewhere" limit; pid_outside=$LAST_PID
# A session an app hosts (T3 Code) at its limit: the app owns it, the takeover never closes or clones it.
id_hosted=66666666-ffff-4fff-8fff-666666666666
new_session "$account_a" "$id_hosted" "$project_root" limit t3-code; pid_hosted=$LAST_PID
usage_cache claude 90 ""
usage_cache claude-b 10 ""
usage_cache claude-c 50 ""

alive() { kill -0 "$1" 2>/dev/null && [[ $(awk '{print $3}' "/proc/$1/stat") != Z ]]; }

# Switch off: nothing is touched. (The service also writes its log lines on stderr, for its journal.)
udarnik _serve --once >/dev/null 2>&1
assert_command 'with the switch off a limited session is left alone' alive "$pid_limit"

mkdir -p "$UDARNIK_STATE"
: >"$UDARNIK_STATE/enabled"
printf 'off\n' >"$UDARNIK_STATE/runners"
printf 'zzzzzzzz\n' >"$UDARNIK_STATE/only"
printf '%s\n' "$project_root" >"$UDARNIK_STATE/root"
udarnik _serve --once >/dev/null 2>&1
assert_command '--only leaves other sessions alone' alive "$pid_limit"
: >"$UDARNIK_STATE/only"
printf 'the owner note' >"$UDARNIK_STATE/context"

# --root: sessions outside the folder are not watched; with no root every directory is.
udarnik status --json >"$test_root/status-root.json"
assert_command '--root: a session outside the folder is not watched and one under it is' \
  jq_check --arg inside "${id_ok:0:8}" --arg outside "${id_outside:0:8}" 'any(.sessions[]; .short == $inside) and (any(.sessions[]; .short == $outside) | not) and .root != null' "$test_root/status-root.json"
rm -f "$UDARNIK_STATE/root"
udarnik status --json >"$test_root/status-noroot.json"
assert_command 'no root: every live session is watched, in any directory, and root is null' \
  jq_check --arg inside "${id_ok:0:8}" --arg outside "${id_outside:0:8}" 'any(.sessions[]; .short == $inside) and any(.sessions[]; .short == $outside) and .root == null' "$test_root/status-noroot.json"
printf '%s\n' "$project_root" >"$UDARNIK_STATE/root"

# The session at its limit is pinned: it changes accounts here like any other.
assert_command 'pin records the id prefix and pins lists it' \
  bash -c 'udarnik pin "${1:0:8}" | grep -q "^Session 11111111 pinned to " && [[ $(cat "$UDARNIK_STATE/pinned") == 11111111 ]] && udarnik pins | grep -q "^  11111111  live: 11111111 "' _ "$id_limit"
assert_command 'pin and unpin refuse what is not a session id' \
  bash -c '! udarnik pin "../x" 2>/dev/null && ! udarnik pin 2>/dev/null && ! udarnik unpin "a b" 2>/dev/null'
# Both log switches arrive exported, as in a shell inside a clone of an older service: the service keeps its own.
UDARNIK_LOG_JOURNAL=1 UDARNIK_LOG_STDOUT=1 udarnik _serve --once >"$test_root/serve1.out" 2>"$test_root/serve1.err" ||
  { cat "$test_root/serve1.out" "$test_root/serve1.err" >&2; true; }
sleep 1
assert_command 'a service that inherited both log switches writes no log line on stdout, and its clone id is read whole' \
  bash -c 'grep -qE " session 11111111: clone [0-9a-f]{8} on claude-b, window c-11111111 \(pid [0-9]+\)$" "$1.err" &&
    ! grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$1.out"' _ "$test_root/serve1"
assert_command 'the clone the service opened inherits neither log switch (not exported to tmux and its windows)' \
  bash -c '[[ $(cat "$1/1.log-switches") == "UNSET UNSET" ]]' _ "$FAKE_CLAUDE_CALLS"
slug=$(slug_of "$project_root/sub")
assert_command 'the original process was closed' bash -c '! kill -0 "$1" 2>/dev/null || [[ $(awk "{print \$3}" /proc/$1/stat) == Z ]]' _ "$pid_limit"
assert_command 'the history and the session folder were copied to the account with quota' \
  bash -c 'cmp "$1/projects/$3/$4.jsonl" "$2/projects/$3/$4.jsonl" && [[ -f $2/projects/$3/$4/subagents/agent-1.jsonl ]]' _ "$account_a" "$account_b" "$slug" "$id_limit"
assert_command 'the clone started once, in the account with the lowest usage, in the original folder' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == 1 && $(cat "$1/1.config") == "$2" && $(cat "$1/1.cwd") == "$3" ]]' _ "$FAKE_CLAUDE_CALLS" "$account_b" "$project_root/sub"
assert_command 'the clone resumes a fork with the model, effort and permission mode of the original' \
  bash -c 'a=$(cat "$1/1.argv"); grep -qx -- "--resume" <<<"$a" && grep -qx "$2" <<<"$a" && grep -qx -- "--fork-session" <<<"$a" && [[ $(grep -x -A1 -- "--model" <<<"$a" | tail -1) == claude-opus-5-5 && $(grep -x -A1 -- "--effort" <<<"$a" | tail -1) == xhigh && $(grep -x -A1 -- "--permission-mode" <<<"$a" | tail -1) == bypassPermissions ]]' _ "$FAKE_CLAUDE_CALLS" "$id_limit"
assert_command 'the takeover message names both accounts, the error, the lost context and the owner note' \
  bash -c 'm=$(tail -n +1 "$1/1.argv" | tr "\n" " "); [[ $m == *"resumed on account ~/.claude-b"* && $m == *"account ~/.claude hit its usage limit"* && $m == *"hit your weekly limit"* && $m == *"subagents, background tasks and messages between sessions"* && $m == *"check the real state"* && $m == *"Owner context: the owner note"* ]]' _ "$FAKE_CLAUDE_CALLS"
assert_command 'the launcher writes the claude command word as is, never an absolute path' \
  bash -c 'l=$(ls "$1"/clones/11111111-*/launch.sh) && grep -qE "exec env CLAUDE_CONFIG_DIR=[^ ]+ claude --resume " "$l"' _ "$UDARNIK_STATE"
assert_command 'the clone runs in a window of the single tmux server' \
  bash -c 'tmux -L "$1" list-windows -F "#{window_name}" | grep -qx "c-11111111" && [[ $(tmux -L "$1" list-sessions | wc -l) == 1 ]]' _ "$socket"
clone_one=$(cat "$FAKE_CLAUDE_CALLS/1.session")
assert_command 'the clone session id was recorded and the original account marked out' \
  bash -c 'jq -e --arg o "$1" --arg c "$2" --arg to "$3" ".[0] | .original == \$o and .clone == \$c and .to == \$to and .state == \"running\" and .from == \"$4\"" "$UDARNIK_STATE/sessions.json" >/dev/null && ! accounts account_available "$4"' _ "$id_limit" "$clone_one" "$account_b" "$account_a"
assert_command 'a session that is fine, a stale limit and a session outside the folder are not touched' \
  bash -c 'for p in "$@"; do kill -0 "$p" || exit 1; done' _ "$pid_ok" "$pid_stale" "$pid_outside"
assert_command 'a session an app hosts (t3-code) at its limit is never closed or cloned, and the log says so once' \
  bash -c 'kill -0 "$1" && ! grep -q "c-66666666" <(tmux -L "$2" list-windows -F "#{window_name}" 2>/dev/null) && [[ $(grep -c "session 66666666 is hosted by t3-code and hit its usage limit" "$UDARNIK_STATE/udarnik.log") == 1 ]]' _ "$pid_hosted" "$socket"
assert_command 'pin: the clone of a pinned session is pinned too' \
  bash -c 'grep -qx "$1" "$UDARNIK_STATE/pinned" && grep -q "clone ${1:0:8} of pinned session 11111111 is pinned too" "$UDARNIK_STATE/udarnik.log"' _ "$clone_one"

# The clone is watched like any session; its copied history still ends in the old error, which must not chain it.
sleep 1
udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'the old error inside the forked history does not take the clone over again' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == 1 ]]' _ "$FAKE_CLAUDE_CALLS"

udarnik status --json >"$test_root/status.json"
status_check() { jq -e "$@" "$test_root/status.json" >/dev/null; }
assert_command 'status --json: the service, the switch, the context, the root and the accounts'   status_check --arg root "$project_root" '.service.active == false and .enabled == true and .context == "the owner note" and .root == $root and (.accounts | length) == 3 and ([.accounts[] | select(.key == "claude") | .available] == [false]) and ([.accounts[] | select(.key == "claude-b") | .weekly_percent] == [10])'
assert_command 'status --json: the runners switch apart from the takeover switch'   status_check '.runners == false and .enabled == true'
assert_command 'status --json: the age and the origin of the weekly usage'   status_check '[.accounts[] | select(.key == "claude-b") | (.weekly_age_seconds | type), (.weekly_from | type), (.weekly_at | type)] == ["number", "string", "number"]'
assert_command 'status --json: the live clone with its original and window'   status_check '(.clones | length) == 1 and .clones[0].alive == true and .clones[0].original == "'"$id_limit"'" and .clones[0].window == "c-11111111"'
assert_command 'status --json: the pinned clone is marked, in the clones and in the watched sessions'   status_check --arg c "$clone_one" '.clones[0].pinned == true and ([.sessions[] | select(.id == $c) | .pinned] == [true]) and ([.sessions[] | select(.short == "22222222") | .pinned] == [false]) and .pinned == ["11111111", $c]'
assert_command 'status prints the runners switch, the weekly age and origin, and the pinned sessions' \
  bash -c 'out=$(udarnik status); grep -qx "Account switching for runners: off" <<<"$out" && grep -qE "^  claude-b: available · weekly 10% \([0-9]+s old, from [^)]+\)$" <<<"$out" && grep -qE "^  [0-9]+  ${1:0:8}  claude-b  ok  pinned  " <<<"$out" && grep -q "c-11111111  alive  since .*  pinned" <<<"$out"' _ "$clone_one"
assert_command 'status --json: watched sessions carry pid, short id, state and the title of the first request'   status_check '([.sessions[] | select(.short == "22222222")] | length) == 1 and ([.sessions[] | select(.short == "22222222") | .state] == ["ok"]) and ([.sessions[] | select(.title == "please fix the thing in the checkout")] | length) >= 1 and ([.sessions[] | select(.short == "33333333") | .state] == ["ok"])'
assert_command 'status prints a readable board'   bash -c 'out=$(udarnik status); grep -q "Accounts" <<<"$out" && grep -q "Clones" <<<"$out" && grep -q "c-11111111" <<<"$out" && grep -q "^Root: " <<<"$out"'
assert_command 'status --json: every tmux window with the session it runs and the attach command'   status_check --arg c "$clone_one" '.view.attach == "tmux -L '"$socket"' attach -t udarnik" and ([.view.windows[] | select(.name == "c-11111111") | [.alive, .session, .attach]] == [[true, $c, "tmux -L '"$socket"' attach -t udarnik:c-11111111"]])'
assert_command 'status ends with the attach command alone on its line, and gives each live window its own'   bash -c 'out=$(udarnik status); [[ $(tail -1 <<<"$out") == "  tmux -L $1 attach -t udarnik" ]] && grep -qx "    tmux -L $1 attach -t udarnik:c-11111111" <<<"$out"' _ "$socket"

# Workers: headless claude processes, the account from CLAUDE_CONFIG_DIR, null when /proc hides the process.
mkdir -p "$test_root/workerbin"
# A process whose executable is named claude (a symlink to python3), so ps reports `claude` as its command name.
ln -s "$(readlink -f "$(command -v python3)")" "$test_root/workerbin/claude"
worker_code='import time; time.sleep(300)'
CLAUDE_CONFIG_DIR="$account_b" "$test_root/workerbin/claude" -I -c "$worker_code" -p 'do the thing' >/dev/null 2>&1 & worker_b=$!
"$test_root/workerbin/claude" -I -c "$worker_code" --print 'do another thing' >/dev/null 2>&1 & worker_a=$!
"$test_root/workerbin/claude" -I -c "$worker_code" --resume nothing >/dev/null 2>&1 & worker_interactive=$!
python3 -I -c 'import ctypes, time
libc = ctypes.CDLL(None)
libc.prctl(4, 0, 0, 0, 0)
libc.prctl(15, b"claude", 0, 0, 0)
time.sleep(300)' -p >/dev/null 2>&1 & worker_hidden=$!
spawned="${spawned:-} $worker_b $worker_a $worker_interactive $worker_hidden"
sleep 1
udarnik status --json >"$test_root/status-workers.json"
assert_command 'workers: -p and --print claude processes are listed with their account and folder' \
  jq_check --argjson b "$worker_b" --argjson a "$worker_a" --arg ab "$account_b" --arg aa "$account_a" --arg cwd "$test_root" \
    '([.workers[] | select(.pid == $b) | [.account, .cwd]] == [[$ab, $cwd]]) and ([.workers[] | select(.pid == $a) | [.account, .cwd]] == [[$aa, $cwd]])' "$test_root/status-workers.json"
assert_command 'workers: an interactive claude is not a worker' \
  jq_check --argjson i "$worker_interactive" 'any(.workers[]; .pid == $i) | not' "$test_root/status-workers.json"
assert_command 'workers: a process /proc hides has a null account and folder instead of failing' \
  jq_check --argjson h "$worker_hidden" '[.workers[] | select(.pid == $h) | [.account, .cwd]] == [[null, null]]' "$test_root/status-workers.json"
assert_command 'status prints the workers' \
  bash -c 'udarnik status | grep -q "pid $1  account claude-b"' _ "$worker_b"
kill "$worker_b" "$worker_a" "$worker_interactive" "$worker_hidden" 2>/dev/null || true

cat >"$test_root/bin/xdg-terminal-exec" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_TERMINAL_ARGS"
FAKE
chmod +x "$test_root/bin/xdg-terminal-exec"
export FAKE_TERMINAL_ARGS="$test_root/terminal.args"
assert_command 'view opens a terminal attached to the tmux server on the window of a session id'   bash -c 'WAYLAND_DISPLAY=test udarnik view "${1:0:8}" >/dev/null && for _ in $(seq 50); do [[ -s $FAKE_TERMINAL_ARGS ]] && break; sleep 0.1; done && [[ $(tr "\n" " " <"$FAKE_TERMINAL_ARGS") == "tmux -L $2 attach -t udarnik " && $(tmux -L "$2" display-message -p -t udarnik "#{window_name}") == c-11111111 ]]' _ "$clone_one" "$socket"
cat >"$test_root/bin/fake-terminal" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_TERMINAL_ARGS"
FAKE
chmod +x "$test_root/bin/fake-terminal"
rm -f "$FAKE_TERMINAL_ARGS"
assert_command 'UDARNIK_TERMINAL is a command prefix and wins over xdg-terminal-exec' \
  bash -c 'WAYLAND_DISPLAY=test UDARNIK_TERMINAL="$1 --flag" udarnik view >/dev/null && for _ in $(seq 50); do [[ -s $FAKE_TERMINAL_ARGS ]] && break; sleep 0.1; done && [[ $(tr "\n" " " <"$FAKE_TERMINAL_ARGS") == "--flag tmux -L $2 attach -t udarnik " ]]' _ "$test_root/bin/fake-terminal" "$socket"
rm -f "$FAKE_TERMINAL_ARGS"
assert_command 'view --print prints the attach command and opens nothing, even with a display'   bash -c 'out=$(WAYLAND_DISPLAY=test DISPLAY=:0 udarnik view --print) && grep -qx "To see: tmux -L $1 attach -t udarnik" <<<"$out" && sleep 0.3 && [[ ! -e $FAKE_TERMINAL_ARGS ]]' _ "$socket"
assert_command 'view without a display prints the attach command and opens nothing'   bash -c 'out=$(unset WAYLAND_DISPLAY DISPLAY; udarnik view) && grep -qx "To see: tmux -L $1 attach -t udarnik" <<<"$out" && sleep 0.3 && [[ ! -e $FAKE_TERMINAL_ARGS ]]' _ "$socket"
assert_command 'view refuses an unknown window'   bash -c '! udarnik view --print nope 2>/dev/null'

# Chain: the clone hits the limit of its own account; a third account takes it over.
sleep 2
clone_pid=$(jq -r --arg id "$clone_one" 'select(.sessionId == $id) | .pid' "$account_b"/sessions/*.json)
jq -cn --arg id "$clone_one" --arg ts "$(iso_now)" --arg text "$(future_text 2)" --argjson resets "$(TZ=America/Sao_Paulo date -d '+2 days 16:00' +%s)" \
  '{type:"assistant", sessionId:$id, timestamp:$ts, isApiErrorMessage:true, error:"rate_limit", quotaLimits:{resetsAt:$resets}, message:{model:"<synthetic>", role:"assistant", content:[{type:"text", text:$text}]}}' \
  >>"$account_b/projects/$slug/$clone_one.jsonl"
udarnik _serve --once >"$test_root/serve2.out" 2>"$test_root/serve2.err" || { cat "$test_root/serve2.out" "$test_root/serve2.err" >&2; true; }
sleep 1
assert_command 'the service journal (stderr) has every line, from service started to the round, and stdout none' \
  bash -c 'grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ service started " "$1.err" && grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ round: " "$1.err" &&
    grep -qE " session ${2:0:8}: clone [0-9a-f]{8} on claude-c, window c-[0-9a-f]{8} \(pid [0-9]+\)$" "$1.err" &&
    ! grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T" "$1.out"' _ "$test_root/serve2" "$clone_one"
assert_command 'chain: the first clone was closed and a second one started in the third account' \
  bash -c '! kill -0 "$1" 2>/dev/null || [[ $(awk "{print \$3}" /proc/$1/stat) == Z ]]; [[ $(find "$2" -name "*.argv" | wc -l) == 2 && $(cat "$2/2.config") == "$3" ]] && grep -qx -- "$4" "$2/2.argv"' _ "$clone_pid" "$FAKE_CLAUDE_CALLS" "$account_c" "$clone_one"
assert_command 'chain: both earlier accounts are out and sessions.json links the whole chain' \
  bash -c '! accounts account_available "$1" && ! accounts account_available "$2" && jq -e --arg a "$3" --arg b "$4" "length == 2 and .[1].original == \$a and .[1].to == \"$5\"" "$UDARNIK_STATE/sessions.json" >/dev/null' _ "$account_a" "$account_b" "$clone_one" "x" "$account_c"

# With every account out nothing is taken over and nothing is closed.
clone_two=$(cat "$FAKE_CLAUDE_CALLS/2.session")
assert_command 'pin: the chain stays pinned, clone after clone' \
  bash -c 'grep -qx "$1" "$UDARNIK_STATE/pinned"' _ "$clone_two"
accounts account_mark_out "$account_c" "$(future_text 2)" >/dev/null
sleep 2
clone_two_pid=$(jq -r --arg id "$clone_two" 'select(.sessionId == $id) | .pid' "$account_c"/sessions/*.json)
jq -cn --arg id "$clone_two" --arg ts "$(iso_now)" --arg text "$(future_text 2)" \
  '{type:"assistant", sessionId:$id, timestamp:$ts, isApiErrorMessage:true, error:"rate_limit", message:{model:"<synthetic>", role:"assistant", content:[{type:"text", text:$text}]}}' \
  >>"$account_c/projects/$slug/$clone_two.jsonl"
udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'with no account left the session is kept running and the log says so' \
  bash -c 'kill -0 "$1" && ! grep -q "ATTENTION" "$2/udarnik.log" && grep -q "no other account is available" "$2/udarnik.log"' _ "$clone_two_pid" "$UDARNIK_STATE"
assert_command 'pin: the pin of a clone that ended stays, with the session and the live clone' \
  bash -c 'jq -e --arg c "$1" "any(.[]; .clone == \$c and .state == \"ended\")" "$UDARNIK_STATE/sessions.json" >/dev/null && grep -qx "$1" "$UDARNIK_STATE/pinned" && grep -qx "$2" "$UDARNIK_STATE/pinned" && grep -qx 11111111 "$UDARNIK_STATE/pinned"' _ "$clone_one" "$clone_two"

# A clone stopped on a permission dialog: a rule only the new account has is answered Yes; a rule the original
# account also has, or one whose original settings cannot be read, is left for a person and logged once with ATTENTION.
cat >"$test_root/dialog.sh" <<'FAKE'
#!/usr/bin/env bash
printf ' Bash command\n   git merge --ff-only fix\n Permission rule %s requires confirmation for this command.\n Do you want to proceed?\n > 1. Yes\n   2. No\n Esc to cancel\n' "$1"
read -r _ && touch "$2"
exec sleep 300
FAKE
jq -n '{permissions:{ask:["Bash(git push:*)"]}}' >"$account_a/settings.json"
dialog_window() { tmux -L "$socket" new-window -d -P -F '#{window_id}' -t udarnik: "bash $test_root/dialog.sh '$1' $test_root/answered-$2"; }
merge_window=$(dialog_window 'Bash(git merge:*)' merge)
push_window=$(dialog_window 'Bash(git push:*)' push)
unread_window=$(dialog_window 'Bash(git merge:*)' unread)
sessions_tmp=$(mktemp)
jq --arg a "$account_a" --arg b "$account_b" --arg m "$merge_window" --arg p "$push_window" --arg u "$unread_window" --arg gone "$test_root/no-account" \
  '. + [{original:"55555555-eeee-4eee-8eee-555555555555", from:$a, clone:"x", to:$b, window:"c-55555555", window_id:$m, state:"running", at:0},
        {original:"66666666-ffff-4fff-8fff-666666666666", from:$a, clone:"y", to:$b, window:"c-66666666", window_id:$p, state:"running", at:0},
        {original:"77777777-aaaa-4aaa-8aaa-777777777777", from:$gone, clone:"z", to:$b, window:"c-77777777", window_id:$u, state:"running", at:0}]' \
  "$UDARNIK_STATE/sessions.json" >"$sessions_tmp" && mv "$sessions_tmp" "$UDARNIK_STATE/sessions.json"
for _ in $(seq 50); do
  for window in "$push_window" "$merge_window" "$unread_window"; do
    tmux -L "$socket" capture-pane -p -t "$window" | grep -q 'Esc to cancel' || { sleep 0.1; continue 2; }
  done
  break
done
udarnik _serve --once >/dev/null 2>&1 || true
udarnik _serve --once >/dev/null 2>&1 || true
sleep 1
assert_command 'a dialog for a rule only the new account has is answered Yes' \
  bash -c '[[ -e "$1/answered-merge" ]] && grep -q "confirmation of Bash(git merge:\*) approved" "$2/udarnik.log"' _ "$test_root" "$UDARNIK_STATE"
assert_command 'a dialog the original account would also show is left for a person and logged once' \
  bash -c '[[ ! -e "$1/answered-push" && $(grep -c "ATTENTION clone of 66666666 .*Bash(git push:\*)" "$2/udarnik.log") == 1 ]]' _ "$test_root" "$UDARNIK_STATE"
assert_command 'a dialog whose original settings cannot be read is never answered' \
  bash -c '[[ ! -e "$1/answered-unread" && $(grep -c "ATTENTION clone of 77777777 .*Bash(git merge:\*)" "$2/udarnik.log") == 1 ]]' _ "$test_root" "$UDARNIK_STATE"

# stop --all ends the clones and the tmux server (systemctl is the stub).
udarnik stop --all >/dev/null 2>&1 || true
assert_command 'stop --all removes the switch and ends every clone' \
  bash -c '[[ ! -e "$1/enabled" ]] && ! tmux -L "$2" list-windows >/dev/null 2>&1' _ "$UDARNIK_STATE" "$socket"

# stop never lets the caller believe that everything stopped while a worker or a runner waiting for quota runs.
mkdir -p "$UDARNIK_STATE"
rm -f "$UDARNIK_STATE"/accounts/*.out-* "$UDARNIK_STATE/udarnik.log"
udarnik runners on >/dev/null
assert_command 'stop says nothing about what still runs when nothing does' \
  bash -c '! udarnik stop | grep -q "Still running here"'
all_out
"$test_root/workerbin/claude" -I -c "$worker_code" -p 'long job' >/dev/null 2>&1 & stop_worker=$!
spawned="${spawned:-} $stop_worker"
sleep 0.5
assert_command 'stop says that a headless worker still runs, that stop does not end it and that stop --all does' \
  bash -c 'out=$(udarnik stop) && grep -qx "Still running here: 1 worker (headless claude); \`udarnik stop\` does not stop them, \`udarnik stop --all\` does." <<<"$out" && kill -0 "$1"' _ "$stop_worker"
udarnik runners on >/dev/null
UDARNIK_WAIT_SLICE=0.3 "$repo_root/bin/udarnik" account wait --label stop-wait >/dev/null 2>&1 & stop_wait=$!
spawned="${spawned:-} $stop_wait"
eventually wait_registered "$stop_wait" || true
assert_command 'stop adds the runners waiting for quota, with the time they wait for, and leaves them waiting' \
  bash -c 'out=$(udarnik stop) && grep -qE "^Still running here: 1 worker \(headless claude\) and 1 runner waiting for quota \(back at [0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}\); " <<<"$out" && kill -0 "$1" && kill -0 "$2"' _ "$stop_worker" "$stop_wait"
assert_command 'stop says it for a wait alone too' \
  bash -c 'kill "$1"; for i in $(seq 50); do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done; out=$(udarnik stop) && grep -qE "^Still running here: 1 runner waiting for quota \(back at [0-9/ :]+\); " <<<"$out" && ! grep -q "worker" <<<"$out"' _ "$stop_worker"
# A headless claude that is an ancestor of the caller (the session that asked) is never ended, and is not reported.
ancestor_code='import subprocess, sys, time
with open(sys.argv[1], "w") as out:
    result = subprocess.run([sys.argv[2], "stop", "--all"], stdout=out, stderr=subprocess.STDOUT)
open(sys.argv[1] + ".rc", "w").write(str(result.returncode))
time.sleep(300)'
"$test_root/workerbin/claude" -I -c "$worker_code" -p 'other job' >/dev/null 2>&1 & stop_worker2=$!
spawned="${spawned:-} $stop_worker2"
sleep 0.5
udarnik runners on >/dev/null
"$test_root/workerbin/claude" -I -c "$ancestor_code" "$test_root/ancestor.out" "$repo_root/bin/udarnik" -p 'asking' >/dev/null 2>&1 & stop_ancestor=$!
spawned="${spawned:-} $stop_ancestor"
eventually test -e "$test_root/ancestor.out.rc" || true
assert_command 'stop --all ends a headless worker and a runner waiting for quota, reports them and exits 0' \
  bash -c 'out=$(cat "$1"); [[ $(cat "$1.rc") == 0 ]] && grep -qx "Ended 1 worker and 1 runner waiting for quota." <<<"$out" && ! grep -q "Still alive" <<<"$out" &&
    ! udarnik account enabled && for pid in "$2" "$3"; do kill -0 "$pid" 2>/dev/null && [[ $(awk "{print \$3}" "/proc/$pid/stat") != Z ]] && exit 1; done; [[ ! -e $UDARNIK_STATE/waits/$3.json ]]' _ "$test_root/ancestor.out" "$stop_worker2" "$stop_wait"
assert_command 'stop --all leaves the process that asked (a headless claude above the caller) alone' \
  bash -c 'kill -0 "$1" && [[ $(awk "{print \$3}" "/proc/$1/stat") != Z ]]' _ "$stop_ancestor"
kill "$stop_ancestor" 2>/dev/null || true
# A process that survives TERM and is registered as a wait is reported by its pid, with exit 1. (The record is made
# by hand: a real wait leaves at once when the switch is off.)
bash -c "trap '' TERM; while :; do sleep 1; done" >/dev/null 2>&1 & stubborn=$!
spawned="${spawned:-} $stubborn"
stubborn_wait() { # <state>: registers the stubborn process as a wait in that state
  mkdir -p "$1/waits"
  jq -cn --argjson pid "$stubborn" --argjson start "$(sed -E 's/^.*\) //' "/proc/$stubborn/stat" | awk '{ print $20 }')" \
    '{pid:$pid, start:$start, label:"stubborn", cwd:"/", since:1, until:2}' >"$1/waits/$stubborn.json"
}
stubborn_wait "$UDARNIK_STATE"
assert_command 'stop --all reports by pid what it could not end and exits 1' \
  bash -c 'rc=0; out=$(UDARNIK_STOP_WAIT=0.4 udarnik stop --all) || rc=$?; [[ $rc == 1 ]] && grep -qx "Ended 0 workers and 0 runners waiting for quota." <<<"$out" && grep -qx "Still alive: runner waiting for quota pid $1." <<<"$out"' _ "$stubborn"
kill -KILL "$stubborn" 2>/dev/null || true
rm -f "$UDARNIK_STATE"/accounts/*.out-* "$UDARNIK_STATE/udarnik.log" "$UDARNIK_STATE"/waits/*

# start with the fake systemd: one transient service from a snapshot, nothing else.
rm -rf "$UDARNIK_STATE" "$FAKE_SYSTEMD_LOG" "$FAKE_SYSTEMD_ACTIVE"
UDARNIK_LINKS=off TZ=Europe/Lisbon UDARNIK_LOG_STDOUT=1 UDARNIK_LOG_JOURNAL=1 \
  udarnik start --context "note" --only abc,def --root "$project_root/sub/../" >/dev/null
assert_command 'start turns the switch on, stores context, filter and root, and starts one transient service from a snapshot' \
  bash -c '[[ -f "$1/enabled" && $(cat "$1/runners") == on && $(cat "$1/context") == note && $(cat "$1/only") == $(printf "abc\ndef") && $(cat "$1/root") == "$3" && -x "$1/snapshot/bin/udarnik" ]] && grep -qx -- "--unit=$UDARNIK_UNIT" "$2" && grep -qx -- "--collect" "$2" && grep -qx "$1/snapshot/bin/udarnik" "$2" && tail -1 "$2" | grep -qx "_serve" && grep -qx -- "--setenv=UDARNIK_STATE=$1" "$2"' _ "$UDARNIK_STATE" "$FAKE_SYSTEMD_LOG" "$project_root"
assert_command 'start gives the unit its description and passes PATH, HOME, TZ and every UDARNIK_ variable' \
  bash -c 'grep -qx -- "--description=udarnik: Claude account takeover" "$1" && grep -qE -- "^--setenv=PATH=(.*:)?$HOME/\.local/bin(:.*)?$" "$1" &&grep -qx -- "--setenv=HOME=$HOME" "$1" && grep -qx -- "--setenv=TZ=Europe/Lisbon" "$1" && grep -qx -- "--setenv=UDARNIK_UNIT=$UDARNIK_UNIT" "$1" && grep -qx -- "--setenv=UDARNIK_TMUX_SOCKET=$2" "$1" && grep -qx -- "--setenv=UDARNIK_CLONE_SCOPE=off" "$1" && grep -qx -- "--setenv=UDARNIK_LINKS=off" "$1"' _ "$FAKE_SYSTEMD_LOG" "$socket"
assert_command 'start never passes the log switches of the caller nor the tests'"'"' clock to the service' \
  bash -c '[[ -n $UDARNIK_CLOCK_OFFSET ]] && ! grep -qE -- "^--setenv=UDARNIK_(LOG_[A-Z_]+|CLOCK_OFFSET)=" "$1"' _ "$FAKE_SYSTEMD_LOG"
assert_command 'the snapshot holds only bin and lib, a copy of the tool tree' \
  bash -c 'cmp "$1/bin/udarnik" "$2/snapshot/bin/udarnik" && cmp "$1/lib/accounts.sh" "$2/snapshot/lib/accounts.sh" && cmp "$1/lib/session_probe.py" "$2/snapshot/lib/session_probe.py" && [[ $(ls "$2/snapshot" | tr "\n" " ") == "bin lib " && ! -e "$2/snapshot.staging" ]]' _ "$repo_root" "$UDARNIK_STATE"
assert_command 'status --json reports the root of the watch' \
  bash -c '[[ $(udarnik status --json | jq -r .root) == "$1" ]]' _ "$project_root"
rm -f "$FAKE_SYSTEMD_LOG"
UDARNIK_LINKS=off udarnik start --context "other" >/dev/null
assert_command 'start with the service already active only updates context, filter and root, and an absent option is cleared' \
  bash -c '[[ ! -e "$2" && $(cat "$1/context") == other && ! -s "$1/only" && ! -e "$1/root" && $(udarnik status --json | jq -r ".root") == null ]]' _ "$UDARNIK_STATE" "$FAKE_SYSTEMD_LOG"
assert_command 'start refuses a --root that is not a directory and changes nothing' \
  bash -c '! UDARNIK_LINKS=off udarnik start --root "$1/nope" 2>/dev/null && [[ $(cat "$2/context") == other ]]' _ "$test_root" "$UDARNIK_STATE"
udarnik stop >"$test_root/stop.out"
assert_command 'stop turns the switch off and leaves the service to exit on its own' \
  bash -c '[[ ! -e "$1/enabled" && -e "$2" ]]' _ "$UDARNIK_STATE" "$FAKE_SYSTEMD_ACTIVE"
assert_command 'stop leaves the account switching of the runners on and says how to turn it off' \
  bash -c 'udarnik account enabled && grep -qx "Account switching for runners stays on; to turn it off: udarnik runners off" "$1"' _ "$test_root/stop.out"

# Started from the snapshot itself, start reuses it instead of copying again.
rm -f "$FAKE_SYSTEMD_ACTIVE" "$FAKE_SYSTEMD_LOG"
snapshot_inode=$(stat -c %i "$UDARNIK_STATE/snapshot")
UDARNIK_LINKS=off "$UDARNIK_STATE/snapshot/bin/udarnik" start >/dev/null
assert_command 'start run from the snapshot reuses it' \
  bash -c '[[ $(stat -c %i "$1/snapshot") == "$2" ]] && tail -2 "$3" | head -1 | grep -qx "$1/snapshot/bin/udarnik"' _ "$UDARNIK_STATE" "$snapshot_inode" "$FAKE_SYSTEMD_LOG"
udarnik stop >/dev/null

# A service with the switch off and no clone leaves by itself.
timeout 20 "$repo_root/bin/udarnik" _serve >/dev/null 2>&1 && pass 'the service exits when the switch is off and no clone is alive' || fail 'the service exits when the switch is off and no clone is alive'

# ---------------------------------------------------------------- kept sessions

# The service of these tests has a state, a tmux server and a claude call log of its own, and watches only the sessions
# whose id starts with "keep" (a kept session is brought back whatever the filter says). UDARNIK_PROC is the folder
# of the cgroup files the fake processes have: the fake systemd-run writes the one of a process it started in a scope.
saved_state=$UDARNIK_STATE saved_calls=$FAKE_CLAUDE_CALLS saved_socket=$UDARNIK_TMUX_SOCKET
export UDARNIK_STATE="$test_root/keep-state" FAKE_CLAUDE_CALLS="$test_root/keep-calls" UDARNIK_TMUX_SOCKET="$socket-keep"
export UDARNIK_PROC="$test_root/fake-proc"
mkdir -p "$UDARNIK_STATE" "$UDARNIK_PROC" "$FAKE_SCOPES" "$FAKE_CLAUDE_CALLS"
rm -f "$FAKE_SCOPES"/*
: >"$UDARNIK_STATE/enabled"
printf 'off\n' >"$UDARNIK_STATE/runners"
printf 'keep\n' >"$UDARNIK_STATE/only"

fake_cgroup() { # <pid> <unit>: the cgroup of a fake process, a scope of the user manager
  mkdir -p "$UDARNIK_PROC/$1"
  printf '0::/user.slice/user-1000.slice/user@1000.service/app.slice/%s\n' "$2" >"$UDARNIK_PROC/$1/cgroup"
}
keep_calls() { find "$FAKE_CLAUDE_CALLS" -name '*.argv' | wc -l; }
kill_session() { kill -KILL "$1" 2>/dev/null || true; eventually bash -c '[[ ! -d /proc/$1 || $(awk "{print \$3}" /proc/$1/stat) == Z ]]' _ "$1"; }
serve_keep() { udarnik _serve --once >"$test_root/keep-serve.out" 2>"$test_root/keep-serve.err" || true; }
kept_pid() { jq -r --arg id "$1" '.[] | select(.id == $id) | .pid' "$UDARNIK_STATE/kept.json"; }

id_k1=keep0001-aaaa-4aaa-8aaa-000000000001
id_k2=keep0002-aaaa-4aaa-8aaa-000000000002
new_session "$account_b" "$id_k1" "$project_root/keep" ok; pid_k1=$LAST_PID
new_session "$account_b" "$id_k2" "$project_root/keep" ok; pid_k2=$LAST_PID
fake_cgroup "$pid_k1" host-one.scope
fake_cgroup "$pid_k2" session-3.scope
touch "$FAKE_SCOPES/host-one.scope"

udarnik keep keep0001 >"$test_root/keep1.out"
assert_command 'keep records the live session whose id starts with the prefix, its process and the scope it runs in' \
  bash -c 'grep -q "^Session keep0001 kept on " "$1" && grep -q "It runs in the scope host-one.scope" "$1" &&
    jq -e --arg id "$2" --argjson pid "$3" "length == 1 and .[0].id == \$id and .[0].pid == \$pid and .[0].scope == \"host-one.scope\" and .[0].account == \"$4\" and (.[0].start | length) > 0" "$UDARNIK_STATE/kept.json" >/dev/null' \
  _ "$test_root/keep1.out" "$id_k1" "$pid_k1" "$account_b"
assert_command 'keep again registers the process again instead of keeping twice' \
  bash -c 'udarnik keep keep0001 | grep -q "already kept" && [[ $(jq length "$UDARNIK_STATE/kept.json") == 1 ]]'
assert_command 'keep refuses a prefix of no live session, a prefix of several, and what is not an id' \
  bash -c '! udarnik keep nothing0 2>/dev/null && ! udarnik keep keep0 2>"$1" && grep -q "2 live sessions start with keep0" "$1" && ! udarnik keep "../x" 2>/dev/null && ! udarnik keep 2>/dev/null && ! udarnik unkeep "a b" 2>/dev/null' _ "$test_root/keep-refuse.err"
# An app (T3 Code) hosts and restarts its own sessions: keeping one would resume it twice.
new_session "$account_b" hosted01-aaaa-4aaa-8aaa-000000000009 "$project_root/keep" ok t3-code
assert_command 'keep refuses a session an app hosts (entrypoint t3-code), and keeps nothing for it' \
  bash -c '! udarnik keep hosted01 2>"$1" && grep -q "hosted by t3-code" "$1" && ! jq -e "any(.[]; .id | startswith(\"hosted01\"))" "$UDARNIK_STATE/kept.json" >/dev/null' _ "$test_root/keep-hosted.err"
for unit in session-3.scope app-kitty-1234.scope tmux-spawn-9.scope vte-spawn-1.scope init.scope; do
  fake_cgroup "$pid_k2" "$unit"
  udarnik keep keep0002 >"$test_root/keep2.out"
  assert_command "keep never records $unit: stopping it would kill more than the session" \
    bash -c 'grep -q "which holds other things too" "$1" && [[ $(jq -r --arg id "$2" ".[] | select(.id == \$id) | .scope" "$UDARNIK_STATE/kept.json") == "" ]]' _ "$test_root/keep2.out" "$id_k2"
done
udarnik status --json >"$test_root/status-keep.json"
assert_command 'status --json: kept lists the sessions with their scope, and a watched session says it is kept' \
  jq_check '(.kept | length) == 2 and ([.kept[] | select(.short == "keep0001") | [.alive, .scope, .resumed, .account]] == [[true, "host-one.scope", 0, "'"$account_b"'"]])
    and ([.kept[] | select(.short == "keep0002") | .scope] == [null]) and ([.sessions[] | select(.short == "keep0001") | .kept] == [true])' "$test_root/status-keep.json"
assert_command 'status prints the kept sessions' \
  bash -c 'out=$(udarnik status); grep -qx "Kept sessions" <<<"$out" && grep -qE "^  keep0001  claude-b  alive  scope host-one.scope" <<<"$out" && grep -qE "^  keep0002  claude-b  alive  scope none" <<<"$out" && grep -qE "^  [0-9]+  keep0001  claude-b  ok  kept  " <<<"$out"'
assert_command 'unkeep removes the sessions the id is the start of, and says when nothing was kept' \
  bash -c 'udarnik unkeep keep0002 | grep -q "no longer kept" && ! udarnik unkeep keep0002 | grep -q "no longer" && udarnik unkeep keep0002 | grep -q "was not kept" && [[ $(jq -r ".[].id" "$UDARNIK_STATE/kept.json") == "$1" ]]' _ "$id_k1"

# A kept session whose process died is resumed: its old scope is stopped (what it left running dies with it), then the
# same session is resumed in a new scope of its own, in the same account, with the message.
kill_session "$pid_k1"
serve_keep
assert_command 'a kept session whose process died is resumed in the tmux of the service, as the same session, in its account, with the message' \
  bash -c 'a=$(cat "$1/1.argv"); [[ $(find "$1" -name "*.argv" | wc -l) == 1 ]] && grep -qx -- "--resume" <<<"$a" && grep -qx "$2" <<<"$a" && ! grep -qx -- "--fork-session" <<<"$a" &&
    [[ $(cat "$1/1.config") == "$3" && $(cat "$1/1.cwd") == "$4" ]] && grep -q "stopped unexpectedly and was resumed. If you are a campaign host, run /campaign-host to register again and continue." "$1/1.argv" &&
    tmux -L "$5" list-windows -F "#{window_name}" | grep -qx k-keep0001' _ "$FAKE_CLAUDE_CALLS" "$id_k1" "$account_b" "$project_root/keep" "$socket-keep"
assert_command 'the resume keeps the model, effort and permission mode of the session' \
  bash -c 'a=$(cat "$1/1.argv"); [[ $(grep -x -A1 -- "--model" <<<"$a" | tail -1) == claude-opus-5-5 && $(grep -x -A1 -- "--effort" <<<"$a" | tail -1) == xhigh && $(grep -x -A1 -- "--permission-mode" <<<"$a" | tail -1) == bypassPermissions ]]' _ "$FAKE_CLAUDE_CALLS"
assert_command 'the old scope was stopped, before the session came back, and the log says so' \
  bash -c 'grep -qx host-one.scope "$FAKE_SCOPES/stopped.log" && [[ ! -e $FAKE_SCOPES/host-one.scope ]] &&
    s=$(grep -n "stopped scope host-one.scope" "$1/udarnik.log" | cut -d: -f1) && r=$(grep -n "kept session keep0001: resumed on claude-b" "$1/udarnik.log" | cut -d: -f1) && ((s < r))' _ "$UDARNIK_STATE"
new_scope=$(ls "$FAKE_SCOPES" | grep -E '^udarnik-keep-keep0001-[0-9]+\.scope$' || true)
assert_command 'it runs in a scope of its own (udarnik-keep-<id8>-<epoch>), which the keep records with the new process' \
  bash -c '[[ -n $1 ]] && grep -qE "exec systemd-run --user --scope --quiet --collect --unit=udarnik-keep-keep0001-[0-9]+ env CLAUDE_CONFIG_DIR=" "$2"/clones/keep0001-*/launch.sh &&
    jq -e --arg id "$3" --arg scope "$1" ".[0] | .id == \$id and .scope == \$scope and .pid != $4 and (.resumes | length) == 1 and .window_id != \"\"" "$2/kept.json" >/dev/null &&
    kill -0 "$(jq -r ".[0].pid" "$2/kept.json")"' _ "$new_scope" "$UDARNIK_STATE" "$id_k1" "$pid_k1"
assert_command 'status: the resumed session is alive and says how many times it came back' \
  bash -c '[[ $(udarnik status --json | jq -c "[.kept[] | [.alive, .resumed]]") == "[[true,1]]" ]] && udarnik status | grep -qE "^  keep0001  claude-b  alive  scope udarnik-keep-keep0001-[0-9]+\.scope  resumed 1x in the last hour"'
assert_command 'a kept session that runs is left alone' \
  bash -c 'for i in 1 2; do UDARNIK_KEEP_BACKOFF=0 udarnik _serve --once >/dev/null 2>&1 || true; done; [[ $(find "$1" -name "*.argv" | wc -l) == 1 ]]' _ "$FAKE_CLAUDE_CALLS"

# Once per UDARNIK_KEEP_BACKOFF seconds, and UDARNIK_KEEP_MAX times per hour.
kill_session "$(kept_pid "$id_k1")"
serve_keep
assert_command 'backoff: a session that died again right after it came back is not resumed before UDARNIK_KEEP_BACKOFF seconds' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == 1 ]]' _ "$FAKE_CLAUDE_CALLS"
UDARNIK_KEEP_BACKOFF=0 UDARNIK_KEEP_MESSAGE='custom words for the host' udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'after the backoff it is resumed again; UDARNIK_KEEP_MESSAGE changes the message; the scope of the first resume was stopped' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == 2 ]] && grep -q "custom words for the host" "$1/2.argv" && ! grep -q "stopped unexpectedly" "$1/2.argv" && grep -qx "$2" "$FAKE_SCOPES/stopped.log" && jq -e ".[0].resumes | length == 2" "$3/kept.json" >/dev/null' _ "$FAKE_CLAUDE_CALLS" "$new_scope" "$UDARNIK_STATE"
kill_session "$(kept_pid "$id_k1")"
UDARNIK_KEEP_BACKOFF=0 UDARNIK_KEEP_MAX=2 udarnik _serve --once >/dev/null 2>"$test_root/keep-cap.err" || true
UDARNIK_KEEP_BACKOFF=0 UDARNIK_KEEP_MAX=2 udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'the hourly cap: after UDARNIK_KEEP_MAX resumes in an hour it is not resumed again, and ATTENTION is logged once' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == 2 ]] && [[ $(grep -c "ATTENTION kept session keep0001: it was resumed 2 times in the last hour (UDARNIK_KEEP_MAX 2)" "$2/udarnik.log") == 1 ]] && grep -q "ATTENTION kept session keep0001" "$3"' _ "$FAKE_CLAUDE_CALLS" "$UDARNIK_STATE" "$test_root/keep-cap.err"
jq --argjson old "$(( $(date +%s) - 4000 ))" '.[0].resumes = [$old, $old + 100]' "$UDARNIK_STATE/kept.json" >"$test_root/kept.new" && mv "$test_root/kept.new" "$UDARNIK_STATE/kept.json"
UDARNIK_KEEP_BACKOFF=0 UDARNIK_KEEP_MAX=2 udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'the hourly cap counts the last hour only: older resumes do not stop it' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == 3 ]] && jq -e ".[0].note == \"\"" "$2/kept.json" >/dev/null' _ "$FAKE_CLAUDE_CALLS" "$UDARNIK_STATE"
pid_now=$(kept_pid "$id_k1")
udarnik unkeep keep0001 >/dev/null
kill_session "$pid_now"
tmux -L "$socket-keep" kill-server 2>/dev/null || true

# A kept session whose history ends at a usage limit is the business of the takeover: the path of the dead is not it.
id_k3=keep0003-aaaa-4aaa-8aaa-000000000003
new_session "$account_b" "$id_k3" "$project_root/keep" limit; pid_k3=$LAST_PID
fake_cgroup "$pid_k3" host-three.scope
touch "$FAKE_SCOPES/host-three.scope"
udarnik keep keep0003 >/dev/null
calls_before=$(keep_calls)
kill_session "$pid_k3"
UDARNIK_KEEP_BACKOFF=0 udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'a kept session that died at a usage limit is not resumed by this path, its scope is left alone and the keep stays' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == "$2" ]] && ! tmux -L "$3" list-windows -F "#{window_name}" 2>/dev/null | grep -qx k-keep0003 && [[ -e $FAKE_SCOPES/host-three.scope ]] &&
    grep -q "kept session keep0003: its process is gone and its history ends at a usage limit" "$4/udarnik.log" && jq -e "length == 1" "$4/kept.json" >/dev/null' _ "$FAKE_CLAUDE_CALLS" "$calls_before" "$socket-keep" "$UDARNIK_STATE"
udarnik unkeep keep0003 >/dev/null

# A session that is not kept is never resumed.
id_k4=keep0004-aaaa-4aaa-8aaa-000000000004
new_session "$account_b" "$id_k4" "$project_root/keep" ok; pid_k4=$LAST_PID
kill_session "$pid_k4"
UDARNIK_KEEP_BACKOFF=0 udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'a session that is not kept and dies is never resumed' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == "$2" ]] && ! tmux -L "$3" list-windows -F "#{window_name}" 2>/dev/null | grep -qx k-keep0004' _ "$FAKE_CLAUDE_CALLS" "$calls_before" "$socket-keep"

# The takeover of a kept session that hit its limit: the old scope is stopped before the fork starts, the fork runs in a
# scope of its own, the keep moves to it, and its message carries the keep message too.
id_k5=keep0005-aaaa-4aaa-8aaa-000000000005
new_session "$account_a" "$id_k5" "$project_root/keep" ok; pid_k5=$LAST_PID
fake_cgroup "$pid_k5" host-five.scope
touch "$FAKE_SCOPES/host-five.scope"
udarnik keep keep0005 >/dev/null
printf '%s\n' "$(jq -cn --arg id "$id_k5" --arg ts "$(iso_now)" --arg text "$(future_text 3)" --argjson resets "$expected" \
  '{type:"assistant", sessionId:$id, timestamp:$ts, isApiErrorMessage:true, error:"rate_limit", quotaLimits:{resetsAt:$resets}, message:{model:"<synthetic>", role:"assistant", content:[{type:"text", text:$text}]}}')" \
  >>"$account_a/projects/$(slug_of "$project_root/keep")/$id_k5.jsonl"
calls_before=$(keep_calls)
udarnik _serve --once >"$test_root/keep-takeover.out" 2>"$test_root/keep-takeover.err" || true
sleep 1
clone_k5=$(cat "$FAKE_CLAUDE_CALLS/$((calls_before + 1)).session")
clone_scope=$(ls "$FAKE_SCOPES" | grep -E '^udarnik-keep-keep0005-[0-9]+\.scope$' || true)
assert_command 'takeover of a kept session: the original closed, its scope stopped before the fork started' \
  bash -c '! kill -0 "$1" 2>/dev/null || [[ $(awk "{print \$3}" /proc/$1/stat) == Z ]]; grep -qx host-five.scope "$FAKE_SCOPES/stopped.log" && [[ ! -e $FAKE_SCOPES/host-five.scope ]] &&
    s=$(grep -n "stopped scope host-five.scope" "$2/udarnik.log" | cut -d: -f1) && c=$(grep -n "session keep0005: clone " "$2/udarnik.log" | cut -d: -f1) && ((s < c))' _ "$pid_k5" "$UDARNIK_STATE"
assert_command 'takeover of a kept session: the fork runs in a scope of its own, and its message carries the takeover text and the keep message' \
  bash -c 'a=$(cat "$1/$2.argv"); grep -qx -- "--fork-session" <<<"$a" && grep -qx "$3" <<<"$a" && [[ -n $4 ]] && grep -q "hit its usage limit" "$1/$2.argv" &&
    grep -q "This session stopped unexpectedly and was resumed. If you are a campaign host, run /campaign-host" "$1/$2.argv" && grep -qE "exec systemd-run --user --scope --quiet --collect --unit=udarnik-keep-keep0005-[0-9]+ env " "$5"/clones/keep0005-*/launch.sh' \
  _ "$FAKE_CLAUDE_CALLS" "$((calls_before + 1))" "$id_k5" "$clone_scope" "$UDARNIK_STATE"
assert_command 'takeover of a kept session: the keep moved to the clone (new id, account, process and scope), the original is no longer kept' \
  bash -c 'jq -e --arg c "$1" --arg o "$2" --arg scope "$3" "length == 1 and .[0].id == \$c and (.[0].id != \$o) and .[0].scope == \$scope and .[0].resumes == [] and (.[0].pid | type) == \"number\"" "$4/kept.json" >/dev/null && grep -q "kept session keep0005: the keep moved to its clone ${1:0:8}" "$4/udarnik.log"' _ "$clone_k5" "$id_k5" "$clone_scope" "$UDARNIK_STATE"
assert_command 'takeover of a kept session starts exactly one scope, the one of the fork' \
  bash -c '[[ $(grep -c "^udarnik-keep-keep0005-" "$FAKE_SCOPES/started.log") == 1 ]]'

# The clone is the new host: when it dies, it is resumed as its own session (the keep follows the chain).
clone_pid=$(kept_pid "$clone_k5")
printf '%s\n' "$(jq -cn --arg id "$clone_k5" --arg ts "$(iso_now)" '{type:"assistant", sessionId:$id, timestamp:$ts, effort:"xhigh", message:{model:"claude-opus-5-5", role:"assistant", content:[{type:"text", text:"back at work"}]}}')" \
  >>"$account_b/projects/$(slug_of "$project_root/keep")/$clone_k5.jsonl"
calls_before=$(keep_calls)
kill_session "$clone_pid"
UDARNIK_KEEP_BACKOFF=0 udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'the clone of a kept session is kept: when it dies it is resumed under its own id, after its scope is stopped' \
  bash -c '(( $(find "$1" -name "*.argv" | wc -l) == $2 + 1 )) && grep -qx -- "$3" "$1/$((${2} + 1)).argv" && ! grep -qx -- "--fork-session" "$1/$((${2} + 1)).argv" && grep -qx "$4" "$FAKE_SCOPES/stopped.log"' _ "$FAKE_CLAUDE_CALLS" "$calls_before" "$clone_k5" "$clone_scope"
udarnik unkeep "${clone_k5:0:8}" >/dev/null
tmux -L "$socket-keep" kill-server 2>/dev/null || true

# Bringing kept sessions back happens only while the takeover is on; stop --all unkeeps nothing.
id_k6=keep0006-aaaa-4aaa-8aaa-000000000006
new_session "$account_b" "$id_k6" "$project_root/keep" ok; pid_k6=$LAST_PID
udarnik keep keep0006 >/dev/null
calls_before=$(keep_calls)
kill_session "$pid_k6"
rm -f "$UDARNIK_STATE/enabled"
UDARNIK_KEEP_BACKOFF=0 udarnik _serve --once >/dev/null 2>&1 || true
udarnik stop --all >/dev/null 2>&1 || true
assert_command 'with the takeover off nothing is resumed, and stop --all keeps the keep' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == "$2" ]] && jq -e --arg id "$3" "length == 1 and .[0].id == \$id" "$4/kept.json" >/dev/null' _ "$FAKE_CLAUDE_CALLS" "$calls_before" "$id_k6" "$UDARNIK_STATE"
: >"$UDARNIK_STATE/enabled"
UDARNIK_KEEP_BACKOFF=0 udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'with the takeover on again the kept session comes back' \
  bash -c '(( $(find "$1" -name "*.argv" | wc -l) == $2 + 1 )) && grep -qx "$3" "$1/$((${2} + 1)).argv"' _ "$FAKE_CLAUDE_CALLS" "$calls_before" "$id_k6"

# A session the owner resumed by hand is registered again, not resumed twice.
kill_session "$(kept_pid "$id_k6")"
new_session "$account_b" "$id_k6" "$project_root/keep" ok; pid_by_hand=$LAST_PID
calls_before=$(keep_calls)
UDARNIK_KEEP_BACKOFF=0 udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'a kept session the owner resumed by hand is registered again under its new pid, never resumed twice' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == "$2" ]] && [[ $(jq -r ".[0].pid" "$3/kept.json") == "$4" ]]' _ "$FAKE_CLAUDE_CALLS" "$calls_before" "$UDARNIK_STATE" "$pid_by_hand"
udarnik unkeep keep0006 >/dev/null
kill "$pid_by_hand" 2>/dev/null || true
tmux -L "$socket-keep" kill-server 2>/dev/null || true
unset UDARNIK_PROC
export UDARNIK_STATE=$saved_state FAKE_CLAUDE_CALLS=$saved_calls UDARNIK_TMUX_SOCKET=$saved_socket

# ---------------------------------------------------------------- several machines (the fleet)

# A second machine, "peer", reached through a fake ssh that runs the command with that machine's environment: its own
# HOME, accounts, state, tmux socket and machine id. This machine is "here". Both read the same fleet file.
saved_state=$UDARNIK_STATE saved_accounts=$UDARNIK_ACCOUNTS saved_calls=$FAKE_CLAUDE_CALLS
export UDARNIK_STATE="$test_root/fleet-state" FAKE_CLAUDE_CALLS="$test_root/fleet-calls"
rm -f "$FAKE_SYSTEMD_ACTIVE"
tmux -L "$socket" kill-server 2>/dev/null || true
peer_home="$test_root/peer-home"
peer_project="$test_root/peer-project"
peer_socket="$socket-peer"
peer_state="$test_root/peer-state"
peer_one="$peer_home/.claude"
peer_x="$peer_home/.claude-x"
peer_z="$peer_home/.claude-z"
mkdir -p "$peer_one" "$peer_x" "$peer_z" "$peer_home/.local/bin" "$peer_project/sub2" "$test_root/hosts" "$UDARNIK_STATE"
ln -s "$repo_root/bin/udarnik" "$peer_home/.local/bin/udarnik"
identity() { jq -cn --arg a "$2" --arg o "$3" '{hasCompletedOnboarding:true, oauthAccount:{accountUuid:$a, organizationUuid:$o}}' >"$1"; }
# The same two accounts on both machines, under other folder names there.
identity "$HOME/.claude.json" user-a org-a
identity "$account_b/.claude.json" user-b org-b
identity "$peer_home/.claude.json" user-a org-a
identity "$peer_x/.claude.json" user-b org-b
# An account only the other machine has.
identity "$peer_z/.claude.json" user-z org-z
jq -n --arg here "$project_root" --arg peer "$peer_project" --arg only "$test_root/only-here" --arg missing "$test_root/missing-there" \
  '{machines:{here:{ssh:"here-host", id:"id-here"}, peer:{ssh:"peer-host", id:"id-peer"}},
    projects:{proj:{paths:{here:$here, peer:$peer}}, gone:{paths:{here:$only, peer:$missing}}}}' >"$test_root/fleet.json"
export UDARNIK_FLEET="$test_root/fleet.json" UDARNIK_MACHINE_ID=id-here UDARNIK_SSH="$test_root/bin/fake-ssh -o BatchMode=yes"
cat >"$test_root/hosts/peer-host.env" <<ENV
export HOME=$(printf %q "$peer_home") PATH=$(printf %q "$test_root/fake-systemd:$test_root/bin:$peer_home/.local/bin:$PATH")
export UDARNIK_STATE=$(printf %q "$peer_state") UDARNIK_ACCOUNTS=$(printf %q "$peer_one:$peer_x:$peer_z")
export UDARNIK_TMUX_SOCKET=$(printf %q "$peer_socket") UDARNIK_UNIT=$(printf %q "$UDARNIK_UNIT-peer") UDARNIK_CLONE_SCOPE=off
export UDARNIK_CLONE_WAIT_SECONDS=20 UDARNIK_FLEET=$(printf %q "$test_root/fleet.json") UDARNIK_MACHINE_ID=id-peer
export UDARNIK_SSH=$(printf %q "$test_root/bin/fake-ssh") UDARNIK_SHARED_DIR=$(printf %q "$peer_home/.claude-shared") UDARNIK_LINKS=off
export FAKE_CLAUDE_CALLS=$(printf %q "$test_root/peer-calls") FAKE_HOSTS=$(printf %q "$test_root/hosts")
export FAKE_SYSTEMD_LOG=$(printf %q "$test_root/peer-systemd.log") FAKE_SYSTEMD_ACTIVE=$(printf %q "$test_root/peer-systemd.active")
export UDARNIK_CLOCK_OFFSET=$(printf %q "$UDARNIK_CLOCK_OFFSET") TMUX_TMPDIR=$(printf %q "$TMUX_TMPDIR")
ENV
cat >"$test_root/bin/fake-ssh" <<'FAKE'
#!/usr/bin/env bash
# fake-ssh [-t] [-o OPTION]... DESTINATION COMMAND: COMMAND runs with the environment of DESTINATION.
while [[ ${1:-} == -* ]]; do if [[ $1 == -o ]]; then shift 2; else shift; fi; done
destination=$1; shift
[[ -f $FAKE_HOSTS/$destination.env ]] || { printf 'ssh: connect to host %s port 22: No route to host\n' "$destination" >&2; exit 255; }
exec env -i bash -c "source $(printf %q "$FAKE_HOSTS/$destination.env"); $*"
FAKE
chmod +x "$test_root/bin/fake-ssh"
export FAKE_HOSTS="$test_root/hosts"
assert_command 'fleet: the other machine runs the udarnik of this checkout, never an installed one' \
  bash -c '[[ $(env -i bash -c "source \"\$1\"; readlink -f \"\$(command -v udarnik)\"" _ "$1/hosts/peer-host.env") == "$2/bin/udarnik" ]]' _ "$test_root" "$repo_root"
peer() { env -i bash -c 'source "$1/hosts/peer-host.env"; shift; "$@"' _ "$test_root" "$@"; }
export -f peer
export test_root
# The sessions of the tests above are not part of these.
for p in ${spawned:-}; do kill "$p" 2>/dev/null || true; done
# The accounts of this machine for these tests: a, b and c, all available.
export UDARNIK_ACCOUNTS="$account_a:$account_b:$account_c"
rm -f "$UDARNIK_STATE"/accounts/*.out-until

# What is told to the other machines is told in the foreground here, so no test races a background ssh.
export UDARNIK_SHARE_WAIT=1
assert_command 'fleet: this machine knows its name and the other one through the fleet file' \
  bash -c '[[ $(udarnik status --json | jq -r .machine) == here && $(peer udarnik status --json | jq -r .machine) == peer ]]'

# The weekly usage read here (the status above read the usage files) is told to the other machine, by identity.
assert_command 'weekly: what this machine reads is told to the other machine, under the folder name there' \
  bash -c '[[ $(jq -c "[.percent, .from]" "$1/accounts/claude-x.weekly") == "[10,\"here\"]" && $(jq -c "[.percent, .from]" "$1/accounts/claude.weekly") == "[90,\"here\"]" ]]' _ "$peer_state"
assert_command 'weekly: the other machine shows it with its age and origin, and picks by it' \
  bash -c 'peer udarnik status --json | jq -e "[.accounts[] | select(.key == \"claude-x\") | [.weekly_percent, .weekly_from, (.weekly_age_seconds | type)]] == [[10, \"here\", \"number\"]]" >/dev/null && [[ $(peer udarnik account pick) == "$1" ]]' _ "$peer_x"
usage_cache claude-b 30 ""
touch -d "@$(( $(date +%s) + 5 ))" "$HOME/.cache/claude-statusline-usage-claude-b.json"
udarnik account pick >/dev/null
assert_command 'weekly: a changed reading is stored here but not told again within 10 minutes' \
  bash -c '[[ $(jq .percent "$UDARNIK_STATE/accounts/claude-b.weekly") == 30 && $(jq .percent "$1/accounts/claude-x.weekly") == 10 ]]' _ "$peer_state"
jq -c '.at -= 601' "$UDARNIK_STATE/accounts/claude-b.weekly-shared" >"$test_root/shared.tmp" && mv "$test_root/shared.tmp" "$UDARNIK_STATE/accounts/claude-b.weekly-shared"
udarnik account current >/dev/null
assert_command 'weekly: ten minutes later the change is told' \
  bash -c '[[ $(jq .percent "$1/accounts/claude-x.weekly") == 30 ]]' _ "$peer_state"
peer_weekly_at=$(jq .at "$peer_state/accounts/claude-x.weekly")
jq -c '.at -= 601' "$UDARNIK_STATE/accounts/claude-b.weekly-shared" >"$test_root/shared.tmp" && mv "$test_root/shared.tmp" "$UDARNIK_STATE/accounts/claude-b.weekly-shared"
touch -d "@$(( $(date +%s) + 8 ))" "$HOME/.cache/claude-statusline-usage-claude-b.json"
udarnik account current >/dev/null
assert_command 'weekly: a newer reading with the same percent is not told' \
  bash -c '[[ $(jq .at "$1/accounts/claude-x.weekly") == "$2" && $(jq .at "$UDARNIK_STATE/accounts/claude-b.weekly") != "$2" ]]' _ "$peer_state" "$peer_weekly_at"
udarnik account learn-weekly user-b/org-b claude-x 55 "" "$(( $(date +%s) + 60 ))" peer
assert_command 'weekly: a reading learned from another machine, newer than the usage file here, is the one used' \
  bash -c 'udarnik account list --json | jq -e "[.[] | select(.key == \"claude-b\") | [.weekly_percent, .weekly_from]] == [[55, \"peer\"]]" >/dev/null && ! grep -q "weekly" "$UDARNIK_STATE/udarnik.log" 2>/dev/null'
udarnik account learn-weekly user-b/org-b claude-x 70 "" "$(( $(date +%s) - 60 ))" peer
assert_command 'weekly: an older reading from another machine changes nothing' \
  bash -c '[[ $(jq .percent "$UDARNIK_STATE/accounts/claude-b.weekly") == 55 ]]'
# A reading on the other machine reaches this one through a fleet status too.
mkdir -p "$peer_home/.cache"
jq -cn '{limits:[{kind:"weekly_all", percent:33, resets_at:null}]}' >"$peer_home/.cache/claude-statusline-usage-claude.json"
touch -d "@$(( $(date +%s) + 30 ))" "$peer_home/.cache/claude-statusline-usage-claude.json"
udarnik status --fleet --json >/dev/null
assert_command 'weekly: status --fleet learns the weekly usage the other machine read' \
  bash -c 'udarnik account list --json | jq -e "[.[] | select(.key == \"claude\") | [.weekly_percent, .weekly_from]] == [[33, \"peer\"]]" >/dev/null'
rm -f "$peer_home/.cache/claude-statusline-usage-claude.json" "$peer_state"/accounts/*.weekly* "$UDARNIK_STATE"/accounts/*.weekly*
usage_cache claude-b 10 ""

# Status of every machine at once, the other machine's attach commands going through ssh.
udarnik status --fleet --json >"$test_root/fleet1.json"
assert_command 'status --fleet lists both machines, this one first-hand and the other through ssh' \
  jq_check '[.machines[] | [.name, .self, .reachable, .status.machine]] == [["here", true, true, "here"], ["peer", false, true, "peer"]]' "$test_root/fleet1.json"
assert_command 'status --fleet: the attach command of the other machine goes through ssh -t' \
  jq_check --arg s "$peer_socket" '.machines[1].status.view.attach == "ssh -t peer-host tmux -L \($s) attach -t udarnik"' "$test_root/fleet1.json"
assert_command 'status --fleet prints one board per machine' \
  bash -c 'out=$(udarnik status --fleet); grep -qx "== here (this machine)" <<<"$out" && grep -qx "== peer" <<<"$out" && [[ $(grep -c "^Accounts" <<<"$out") == 2 ]]'
mv "$test_root/hosts/peer-host.env" "$test_root/hosts/peer-host.off"
udarnik status --fleet --json >"$test_root/fleet2.json"
mv "$test_root/hosts/peer-host.off" "$test_root/hosts/peer-host.env"
assert_command 'status --fleet: an unreachable machine shows the last status seen, with its time' \
  jq_check '.machines[1] | .reachable == false and .seen_at != null and .status.machine == "peer"' "$test_root/fleet2.json"
assert_command 'status --fleet text says when a machine is unreachable' \
  bash -c 'mv "$1/hosts/peer-host.env" "$1/hosts/peer-host.off"; out=$(udarnik status --fleet); mv "$1/hosts/peer-host.off" "$1/hosts/peer-host.env"; grep -q "^== peer (unreachable; last seen " <<<"$out"' _ "$test_root"
assert_command 'status --on runs on the other machine' \
  bash -c 'out=$(udarnik status --on peer) && grep -qx "== peer" <<<"$out" && [[ $(udarnik status --on peer --json | jq -r .machine) == peer ]]'

# Account state: an account out of quota here is out on the other machine too, matched by identity.
limit_at=$(date +%s)
UDARNIK_SHARE_WAIT=1 bash -c 'printf "%s" "$1" | udarnik account limit "$2" >/dev/null' _ "$(future_text 2)" "$account_b" || true
assert_command 'an account at its limit here is marked out on the other machine, under its folder name there' \
  bash -c '[[ $(cat "$1/accounts/claude-x.out-until") == "$2" ]] && grep -q "account claude-x is out of quota until .* (learned from here)" "$1/udarnik.log"' _ "$peer_state" "$(TZ=America/Sao_Paulo date -d '+2 days 16:00' +%s)"
assert_command 'the other machine records the time of the news, as this machine marked it, and that it came from here' \
  bash -c 'here_at=$(cut -d" " -f1 "$UDARNIK_STATE/accounts/claude-b.out-news"); (( here_at >= $2 && here_at <= $(date +%s) )) && [[ $(cat "$1/accounts/claude-x.out-news") == "$here_at here" ]]' _ "$peer_state" "$limit_at"
assert_command 'learning an earlier or equal time changes nothing' \
  bash -c 'before=$(cat "$1/accounts/claude-x.out-until"); peer udarnik account learn user-b/org-b claude-b "$(( before - 100 ))" here; [[ $(cat "$1/accounts/claude-x.out-until") == "$before" ]]' _ "$peer_state"
assert_command 'account learn: a newer news of the same machine moves it earlier there, one of another machine never does' \
  bash -c 'before=$(cat "$1/accounts/claude-x.out-until"); at=$(cut -d" " -f1 "$1/accounts/claude-x.out-news")
    peer udarnik account learn user-b/org-b claude-b "$(( before - 600 ))" box "$(( at + 5 ))"
    [[ $(cat "$1/accounts/claude-x.out-until") == "$before" ]] || exit 1
    peer udarnik account learn user-b/org-b claude-b "$(( before - 600 ))" here "$(( at + 5 ))"
    [[ $(cat "$1/accounts/claude-x.out-until") == $(( before - 600 )) && $(cat "$1/accounts/claude-x.out-news") == "$(( at + 5 )) here" ]]' _ "$peer_state"
printf '%s\n' "$(( $(date +%s) + 7200 ))" >"$peer_state/accounts/claude.out-until"
udarnik status --fleet --json >/dev/null
assert_command 'status --fleet learns the accounts the other machine knows to be out' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude.out-until") == $(cat "$1/accounts/claude.out-until") ]]' _ "$peer_state"
rm -f "$UDARNIK_STATE"/accounts/*.out-until "$peer_state"/accounts/*.out-until
# This machine lowers its own epoch (a later text with an earlier `resets`) while the peer still holds the old news,
# which it learned from here: the fleet status brings it back with this machine as its origin, and it is not learned.
accounts account_mark_out "$account_b" "$(future_text 3)" >/dev/null
lowered_from=$(cat "$UDARNIK_STATE/accounts/claude-b.out-until")
peer udarnik account learn user-b/org-b claude-b "$lowered_from" here >/dev/null
accounts account_mark_out "$account_b" "$(future_text 2)" >/dev/null
lowered_to=$(cat "$UDARNIK_STATE/accounts/claude-b.out-until")
udarnik status --fleet --json >/dev/null
assert_command 'status --fleet: the old news of this machine comes back from the peer and does not raise the epoch it lowered' \
  bash -c '(( $2 < $3 )) && [[ $(cat "$1/accounts/claude-b.out-until") == "$2" && $(cat "$4/accounts/claude-x.out-until") == "$3" ]]' _ "$UDARNIK_STATE" "$lowered_to" "$lowered_from" "$peer_state"
rm -f "$UDARNIK_STATE"/accounts/*.out-until "$peer_state"/accounts/*.out-until

# A call that worked clears the account for the whole fleet (account clear / learn-clear).
forget_marks() { rm -f "$UDARNIK_STATE"/accounts/*.out-* "$UDARNIK_STATE"/accounts/*.back-at "$peer_state"/accounts/*.out-* "$peer_state"/accounts/*.back-at; }
forget_marks
clear_spy="$test_root/bin/ssh-spy"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\nexit 255\n' "$test_root/ssh-spy.calls" >"$clear_spy"
chmod +x "$clear_spy"
log_lines_before=$(wc -l <"$UDARNIK_STATE/udarnik.log")
assert_command 'account clear: an account that is not marked out does nothing, exits 0 and does not use ssh' \
  bash -c 'UDARNIK_SSH="$1" udarnik account clear "$2" && UDARNIK_SSH="$1" udarnik account clear --kind worker "$2" && [[ ! -e $3 && $(wc -l <"$UDARNIK_STATE/udarnik.log") == "$4" ]] && ! ls "$UDARNIK_STATE"/accounts/claude-b.out-* >/dev/null 2>&1' _ "$clear_spy" "$account_b" "$test_root/ssh-spy.calls" "$log_lines_before"
# An account out of quota here and there, learned long enough ago for the clear to be newer than the news.
mark_both() { # <seconds ago the news was learned>
  local epoch=$(( $(date +%s) + 7200 )) at=$(( $(date +%s) - $1 ))
  forget_marks
  accounts account_learn_out "$account_b" "$epoch" "$at" here
  peer udarnik account learn user-b/org-b claude-b "$epoch" here "$at"
}
mark_both 100
udarnik account clear "$account_b"
assert_command 'account clear: an account marked out is back here (both files gone) and the log says it' \
  bash -c '! ls "$UDARNIK_STATE"/accounts/claude-b.out-* >/dev/null 2>&1 && grep -q "account claude-b is back (a call worked)" "$UDARNIK_STATE/udarnik.log"'
assert_command 'account clear: the other machine is told, by identity, and drops its mark under its folder name' \
  bash -c '! ls "$1"/accounts/claude-x.out-* >/dev/null 2>&1 && grep -q "account claude-x is back (a call worked on here)" "$1/udarnik.log"' _ "$peer_state"
assert_command 'account clear: nothing is left to do on a second call' \
  bash -c 'before=$(wc -l <"$UDARNIK_STATE/udarnik.log"); UDARNIK_SSH="$1" udarnik account clear "$2" && [[ ! -e $3 && $(wc -l <"$UDARNIK_STATE/udarnik.log") == "$before" ]]' _ "$clear_spy" "$account_b" "$test_root/ssh-spy.calls"
# learn-clear: the mark is dropped only when its news is older than the call that worked.
mark_both 100
peer udarnik account learn-clear user-b/org-b claude-b "$(( $(date +%s) - 50 ))" box
assert_command 'account learn-clear: a mark older than the call that worked is dropped, whatever machine told the call' \
  bash -c '! ls "$1"/accounts/claude-x.out-* >/dev/null 2>&1' _ "$peer_state"
mark_both 100
peer udarnik account learn-clear user-b/org-b claude-b "$(( $(date +%s) - 200 ))" box
assert_command 'account learn-clear: a mark newer than the call that worked stays' \
  bash -c '[[ -f $1/accounts/claude-x.out-until && -f $1/accounts/claude-x.out-news ]] && peer udarnik account learn-clear user-b/org-b claude-b 5 box && [[ -f $1/accounts/claude-x.out-until ]]' _ "$peer_state"
assert_command 'account learn-clear: a clear of this very machine coming back from another is ignored' \
  bash -c 'peer udarnik account learn-clear user-b/org-b claude-b "$(( $(date +%s) + 60 ))" peer && [[ -f $1/accounts/claude-x.out-until ]] && peer udarnik account learn-clear user-b/org-b claude-b "$(( $(date +%s) + 60 ))" box && [[ ! -e $1/accounts/claude-x.out-until ]]' _ "$peer_state"
assert_command 'account learn-clear: an account the machine does not have is ignored' \
  bash -c 'peer udarnik account learn-clear user-q/org-q claude-q "$(( $(date +%s) + 60 ))" box'
# --at: the end of the call, not the time of the command; a mark made after the call stays, here and there.
mark_both 100
udarnik account clear --at "$(( $(date +%s) - 200 ))" "$account_b"
assert_command 'account clear --at: a mark made after the call that ended at --at stays here and on the other machine' \
  bash -c '[[ -f $1/accounts/claude-b.out-until && -f $2/accounts/claude-x.out-until ]]' _ "$UDARNIK_STATE" "$peer_state"
udarnik account clear --at "$(( $(date +%s) - 50 ))" "$account_b"
assert_command 'account clear --at: a call that ended after the mark clears it here and on the other machine' \
  bash -c '! ls "$1"/accounts/claude-b.out-until "$2"/accounts/claude-x.out-until >/dev/null 2>&1' _ "$UDARNIK_STATE" "$peer_state"
assert_command 'account clear --at: a value that is not an epoch is refused' \
  bash -c '! udarnik account clear --at soon "$1" 2>/dev/null' _ "$account_b"
# The clear leaves a trace: an "out" news not newer than the call is the one it proved wrong, arriving late.
forget_marks
clear_at=$(( $(date +%s) - 50 ))
peer udarnik account learn-clear user-b/org-b claude-b "$clear_at" box
peer udarnik account learn user-b/org-b claude-b "$(( $(date +%s) + 7200 ))" box "$(( clear_at - 30 ))"
assert_command 'account learn-clear then learn: an "out" news older than the clear leaves the account free, even with no mark to clear' \
  bash -c '[[ $(cat "$1/accounts/claude-x.back-at") == "$2" ]] && ! ls "$1"/accounts/claude-x.out-* >/dev/null 2>&1' _ "$peer_state" "$clear_at"
peer udarnik account learn user-b/org-b claude-b "$(( $(date +%s) + 7200 ))" box "$clear_at"
assert_command 'account learn: an "out" news with the very time of the clear is rejected too' \
  bash -c '! ls "$1"/accounts/claude-x.out-* >/dev/null 2>&1' _ "$peer_state"
peer udarnik account learn-clear user-b/org-b claude-b "$(( clear_at - 500 ))" box
assert_command 'account learn-clear: an older clear does not move the trace back' \
  bash -c '[[ $(cat "$1/accounts/claude-x.back-at") == "$2" ]]' _ "$peer_state" "$clear_at"
peer udarnik account learn user-b/org-b claude-b "$(( $(date +%s) + 7200 ))" box "$(( clear_at + 10 ))"
assert_command 'account learn: an "out" news made after the clear marks the account' \
  bash -c '[[ -f $1/accounts/claude-x.out-until ]]' _ "$peer_state"
forget_marks
peer udarnik account learn-clear user-b/org-b claude-b "$clear_at" box
peer udarnik account learn user-b/org-b claude-b "$(( $(date +%s) + 7200 ))" box
assert_command 'account learn: a news without a time is accepted when its out-until is later than the clear' \
  bash -c '[[ -f $1/accounts/claude-x.out-until ]]' _ "$peer_state"
forget_marks
# The trace is ahead of now here (a clear a few minutes ahead of this machine), so that anything that consulted it would show.
back_ahead=$(( $(date +%s) + 600 ))
printf '%s\n' "$back_ahead" >"$peer_state/accounts/claude-x.back-at"
peer udarnik account learn user-b/org-b claude-b "$(( back_ahead - 100 ))" box
assert_command 'account learn: a news without a time is rejected when its out-until is not later than the clear' \
  bash -c '! ls "$1"/accounts/claude-x.out-until >/dev/null 2>&1' _ "$peer_state"
forget_marks
printf '%s\n' "$back_ahead" >"$UDARNIK_STATE/accounts/claude-b.back-at"
udarnik account limit "$account_b" <<<"$(future_text 2)" >/dev/null || true
assert_command 'a limit marked here and now wins over the trace of a clear, even one ahead of now' \
  bash -c '[[ -f $1/accounts/claude-b.out-until ]]' _ "$UDARNIK_STATE"
# A time in the future is never kept: it would free a mark made after the call and reject every later news of "out".
forget_marks
peer udarnik account learn-clear user-b/org-b claude-b "$(( $(date +%s) + 86400 ))" box
sleep 1
peer udarnik account learn user-b/org-b claude-b "$(( $(date +%s) + 7200 ))" box "$(date +%s)"
assert_command 'account learn-clear: an AT in the future is taken as now, so it leaves no trace ahead of the clock and a news of now marks' \
  bash -c '[[ $(cat "$1/accounts/claude-x.back-at") -lt $(date +%s) && -f $1/accounts/claude-x.out-until ]]' _ "$peer_state"
forget_marks
peer udarnik account learn user-b/org-b claude-b "$(( $(date +%s) + 7200 ))" box "$(( $(date +%s) + 5 ))"
peer udarnik account learn-clear user-b/org-b claude-b "$(( $(date +%s) * 1000 ))" box
assert_command 'account learn-clear: an AT in milliseconds does not free a mark made after the call that just ended' \
  bash -c '[[ -f $1/accounts/claude-x.out-until ]]' _ "$peer_state"
forget_marks
assert_command 'account clear --at: a time after the command was entered is refused with exit 2' \
  bash -c 'udarnik account clear --at "$(( $(date +%s) + 86400 ))" "$1" 2>/dev/null; first=$?; udarnik account clear --at "$(( $(date +%s) * 1000 ))" "$1" 2>/dev/null; [[ $first == 2 && $? == 2 ]] && [[ ! -e $2/accounts/claude-b.back-at ]]' _ "$account_b" "$UDARNIK_STATE"
# An account that is not marked out keeps the time of the call, so the mark that reaches it later, made before, is rejected.
forget_marks
call_at=$(( $(date +%s) - 20 ))
udarnik account clear --at "$call_at" "$account_b"
assert_command 'account clear: an account that is not marked out keeps the time of the call, and never moves it back' \
  bash -c '[[ $(cat "$1/accounts/claude-b.back-at") == "$2" ]] && udarnik account clear --at "$(( $2 - 10 ))" "$3" && [[ $(cat "$1/accounts/claude-b.back-at") == "$2" ]]' _ "$UDARNIK_STATE" "$call_at" "$account_b"
accounts account_learn_out "$account_b" "$(( $(date +%s) + 7200 ))" "$(( call_at - 30 ))" peer || true
assert_command 'account clear: a mark made before a call that worked here, learned after it, leaves the account free' \
  bash -c '! ls "$1"/accounts/claude-b.out-until >/dev/null 2>&1' _ "$UDARNIK_STATE"
# A peer that kept the old mark (it missed the clear) does not mark this machine again through status --fleet.
forget_marks
peer udarnik account learn user-b/org-b claude-b "$(( $(date +%s) + 7200 ))" box "$(( clear_at - 30 ))"
accounts account_learn_clear "$account_b" "$clear_at" || true
udarnik status --fleet --json >/dev/null
assert_command 'status --fleet: the old mark kept by a peer does not mark again a machine that knows the clear' \
  bash -c '! ls "$1"/accounts/claude-b.out-until >/dev/null 2>&1' _ "$UDARNIK_STATE"
forget_marks

# start and stop on another machine, or on every machine.
udarnik start --on peer >"$test_root/start-peer.out" 2>&1 || true
assert_command 'start --on turns the takeover on there only, and its attach command goes through ssh' \
  bash -c '[[ -f $1/enabled && ! -f $UDARNIK_STATE/enabled ]] && grep -q "ssh -t peer-host tmux -L $2 attach -t udarnik" "$3"' _ "$peer_state" "$peer_socket" "$test_root/start-peer.out"
UDARNIK_LINKS=off udarnik start >/dev/null
udarnik stop --fleet >"$test_root/stop-fleet.out" 2>&1 || true
assert_command 'stop --fleet turns it off on every machine' \
  bash -c '[[ ! -f $1/enabled && ! -f $UDARNIK_STATE/enabled ]] && grep -qx "== here" "$2" && grep -qx "== peer" "$2"' _ "$peer_state" "$test_root/stop-fleet.out"
rm -f "$FAKE_SYSTEMD_ACTIVE" "$test_root/peer-systemd.active"
assert_command 'runners --fleet: the runners stay on everywhere after stop, and turn off on every machine' \
  bash -c 'peer udarnik account enabled && udarnik account enabled && out=$(udarnik runners off --fleet) && ! peer udarnik account enabled && ! udarnik account enabled && grep -qx "== peer" <<<"$out"'
assert_command 'runners --on turns the runners on there only' \
  bash -c 'udarnik runners on --on peer >/dev/null && peer udarnik account enabled && ! udarnik account enabled && [[ $(udarnik runners status --on peer) == "Account switching for runners: on" ]]'
udarnik runners off --on peer >/dev/null

# Moving a live session: closed here, history there, a fork resumed in the other machine's tmux, in the folder the
# fleet file maps.
id_move=88888888-aaaa-4aaa-8aaa-888888888888
new_session "$account_a" "$id_move" "$project_root/sub2" ok; pid_move=$LAST_PID
udarnik keep "${id_move:0:8}" >/dev/null
# An account this machine learned is out, from a third machine: the move hands it over with that time and machine.
move_news_at=$(( $(date +%s) - 30 ))
accounts account_learn_out "$account_b" $(( $(date +%s) + 7200 )) "$move_news_at" kepler
udarnik move "${id_move:0:8}" --to peer >"$test_root/move.out" 2>&1 || cat "$test_root/move.out" >&2
peer_slug=$(slug_of "$peer_project/sub2")
assert_command 'move: the session closed here' \
  bash -c '! kill -0 "$1" 2>/dev/null || [[ $(awk "{print \$3}" /proc/$1/stat) == Z ]]' _ "$pid_move"
assert_command 'move: the keep of a session that leaves stays behind, dropped (the service here would resume the closed session), and the log says how to keep the clone' \
  bash -c '[[ $(jq length "$UDARNIK_STATE/kept.json") == 0 ]] && grep -q "session 88888888 was kept here; the keep does not follow it. To keep the clone there: udarnik keep [0-9a-f]\{8\} --on peer" "$UDARNIK_STATE/udarnik.log"'
assert_command 'move: the history and the session folder arrived in the same account there, under the mapped folder' \
  bash -c 'cmp "$1" "$2/projects/$3/$4.jsonl" && [[ -f $2/projects/$3/$4/subagents/agent-1.jsonl ]]' _ "$account_a/projects/$(slug_of "$project_root/sub2")/$id_move.jsonl" "$peer_one" "$peer_slug" "$id_move"
assert_command 'move: a fork resumed there, in the mapped folder, with the model, effort and permission mode' \
  bash -c 'a=$(cat "$1/1.argv"); [[ $(cat "$1/1.cwd") == "$2" && $(cat "$1/1.config") == UNSET ]] && grep -qx "$3" <<<"$a" && grep -qx -- "--fork-session" <<<"$a" && [[ $(grep -x -A1 -- "--effort" <<<"$a" | tail -1) == xhigh ]]' _ "$test_root/peer-calls" "$peer_project/sub2" "$id_move"
assert_command 'move: the fork is told where it came from and that uncommitted changes stayed behind' \
  bash -c 'm=$(tr "\n" " " <"$1/1.argv"); [[ $m == *"moved from machine here (folder $2) to machine peer (folder $3)"* && $m == *"not committed and pushed on here"* && $m == *"the owner moved it"* ]]' _ "$test_root/peer-calls" "$project_root/sub2" "$peer_project/sub2"
assert_command 'move: the fork runs in the tmux of the other machine' \
  bash -c 'tmux -L "$1" list-windows -F "#{window_name}" | grep -qx c-88888888' _ "$peer_socket"
assert_command 'move: prints the command that attaches to it from here' \
  bash -c 'grep -qx "  ssh -t peer-host tmux -L $1 attach -t udarnik:c-88888888" "$2"' _ "$peer_socket" "$test_root/move.out"
assert_command 'move: both machines record it (moved here, arrived there)' \
  bash -c 'jq -e --arg id "$1" "any(.[]; .original == \$id and .state == \"moved\" and .machine == \"peer\" and .window == \"c-88888888\")" "$UDARNIK_STATE/sessions.json" >/dev/null && jq -e --arg id "$1" "any(.[]; .original == \$id and .came_from == \"here\" and .state == \"running\")" "$2/sessions.json" >/dev/null' _ "$id_move" "$peer_state"
assert_command 'move: an account out here is out there too, with the time and the machine of the news' \
  bash -c '[[ $(cat "$1/accounts/claude-x.out-until") == $(cat "$UDARNIK_STATE/accounts/claude-b.out-until") && $(cat "$1/accounts/claude-x.out-news") == "$2 kepler" ]]' _ "$peer_state" "$move_news_at"
rm -f "$UDARNIK_STATE"/accounts/*.out-* "$peer_state"/accounts/*.out-*
assert_command 'status shows the moved session with its attach command' \
  bash -c 'out=$(udarnik status); grep -q "^Moved to other machines" <<<"$out" && grep -q "88888888 -> peer" <<<"$out" && grep -qx "    ssh -t peer-host tmux -L $1 attach -t udarnik:c-88888888" <<<"$out"' _ "$peer_socket"
assert_command 'view --on prints the attach command of a window of the other machine' \
  bash -c 'out=$(udarnik view --on peer c-88888888 --print) && grep -qx "To see: ssh -t peer-host tmux -L $1 attach -t udarnik:c-88888888" <<<"$out"' _ "$peer_socket"

# From here, the other machine moves one of its sessions here: what is printed here attaches here, without ssh.
cat >"$test_root/hosts/here-host.env" <<ENV
export HOME=$(printf %q "$HOME") PATH=$(printf %q "$test_root/fake-systemd:$test_root/bin:$repo_root/bin:$PATH")
export UDARNIK_STATE=$(printf %q "$UDARNIK_STATE") UDARNIK_ACCOUNTS=$(printf %q "$UDARNIK_ACCOUNTS")
export UDARNIK_TMUX_SOCKET=$(printf %q "$socket") UDARNIK_UNIT=$(printf %q "$UDARNIK_UNIT") UDARNIK_CLONE_SCOPE=off
export UDARNIK_CLONE_WAIT_SECONDS=20 UDARNIK_FLEET=$(printf %q "$test_root/fleet.json") UDARNIK_MACHINE_ID=id-here
export UDARNIK_SSH=$(printf %q "$test_root/bin/fake-ssh") UDARNIK_SHARED_DIR=$(printf %q "$HOME/.claude-shared") UDARNIK_LINKS=off
export FAKE_CLAUDE_CALLS=$(printf %q "$FAKE_CLAUDE_CALLS") FAKE_HOSTS=$(printf %q "$test_root/hosts")
export FAKE_SYSTEMD_LOG=$(printf %q "$FAKE_SYSTEMD_LOG") FAKE_SYSTEMD_ACTIVE=$(printf %q "$FAKE_SYSTEMD_ACTIVE")
export UDARNIK_CLOCK_OFFSET=$(printf %q "$UDARNIK_CLOCK_OFFSET") TMUX_TMPDIR=$(printf %q "$TMUX_TMPDIR")
ENV
id_back=cccccccc-eeee-4eee-8eee-cccccccccccc
HOME=$peer_home new_session "$peer_one" "$id_back" "$peer_project/sub2" ok; pid_back=$LAST_PID
udarnik move "${id_back:0:8}" --on peer --to here >"$test_root/move-back.out" 2>&1 || cat "$test_root/move-back.out" >&2
assert_command 'move --on: the other machine moves its session here, and the attach command printed here has no ssh' \
  bash -c '(! kill -0 "$1" 2>/dev/null || [[ $(awk "{print \$3}" /proc/$1/stat) == Z ]]) && grep -qx "  tmux -L $2 attach -t udarnik:c-cccccccc" "$3" && tmux -L "$2" list-windows -F "#{window_name}" | grep -qx c-cccccccc' _ "$pid_back" "$socket" "$test_root/move-back.out"
assert_command 'move --on: the clone here resumed in the folder this machine maps' \
  bash -c 'n=$(grep -lx "$1" "$2"/*.argv | head -1) && [[ $(cat "${n%.argv}.cwd") == "$3" ]]' _ "$id_back" "$FAKE_CLAUDE_CALLS" "$project_root/sub2"
assert_command 'status --fleet: the moved session seen from the machine it went to attaches without ssh' \
  bash -c 'peer udarnik status --fleet --json | jq -e --arg s "$1" "[.machines[] | select(.name == \"here\") | .status.moved[] | select(.window == \"c-88888888\") | .attach] == [\"tmux -L \(\$s) attach -t udarnik:c-88888888\"]" >/dev/null' _ "$peer_socket"

id_nofolder=99999999-bbbb-4bbb-8bbb-999999999999
new_session "$account_a" "$id_nofolder" "$test_root/only-here" ok; pid_nofolder=$LAST_PID
assert_command 'move: refused, and the session left alone, when its folder does not exist there' \
  bash -c 'out=$(udarnik move "${1:0:8}" --to peer 2>&1) && exit 1; grep -q "does not exist on peer" <<<"$out" && kill -0 "$2"' _ "$id_nofolder" "$pid_nofolder"
assert_command 'move: refuses this machine and unknown machines' \
  bash -c '! udarnik move "${1:0:8}" --to here 2>/dev/null && ! udarnik move "${1:0:8}" --to nowhere 2>/dev/null' _ "$id_nofolder"
kill "$pid_nofolder" 2>/dev/null || true

# Moved from inside itself (the session is an ancestor of the move command): the move goes on detached. Its folder
# does not exist there, so the detached move refuses it and the session stays.
id_self=abababab-aaaa-4aaa-8aaa-abababababab
new_session "$account_a" "$id_self" "$test_root/only-here" ok
kill "$LAST_PID" 2>/dev/null || true
bash -c 'while [[ ! -e $2 ]]; do sleep 0.1; done; udarnik move "${1:0:8}" --to peer >"$3" 2>&1; sleep 300' \
  _ "$id_self" "$test_root/self-ready" "$test_root/move-self.out" & pid_self=$!
spawned="${spawned:-} $pid_self"
jq --argjson pid "$pid_self" '.pid = $pid' "$account_a/sessions/$LAST_PID.json" >"$account_a/sessions/$pid_self.json"
rm -f "$account_a/sessions/$LAST_PID.json" "$UDARNIK_STATE/move.out"
touch "$test_root/self-ready"
for _ in $(seq 100); do grep -q 'does not exist on peer' "$UDARNIK_STATE/move.out" 2>/dev/null && break; sleep 0.2; done
assert_command 'move: from inside the session itself, the move goes on detached and says so' \
  bash -c 'grep -q "^This is the session being moved: it closes in a moment and continues on peer" "$1" && grep -q "does not exist on peer" "$2" && kill -0 "$3"' \
  _ "$test_root/move-self.out" "$UDARNIK_STATE/move.out" "$pid_self"
kill $(pgrep -P "$pid_self") "$pid_self" 2>/dev/null || true
rm -f "$account_a/sessions/$pid_self.json"

# A pinned session never moves: move refuses it, exit 1, and nothing is closed.
id_pinned=dddddddd-aaaa-4aaa-8aaa-dddddddddddd
new_session "$account_a" "$id_pinned" "$project_root/sub2" ok; pid_pinned=$LAST_PID
udarnik pin "${id_pinned:0:8}" >/dev/null
assert_command 'move refuses a pinned session with exit 1, says why and closes nothing' \
  bash -c 'code=0; out=$(udarnik move "${1:0:8}" --to peer 2>&1) || code=$?; [[ $code == 1 ]] && grep -q "session dddddddd is pinned to here: it changes accounts here but never moves to another machine; nothing was closed. To move it, first: udarnik unpin dddddddd" <<<"$out" && kill -0 "$2" && ! tmux -L "$3" list-windows -F "#{window_name}" | grep -qx c-dddddddd' _ "$id_pinned" "$pid_pinned" "$peer_socket"
# A clone that ended (its record is `ended`) and comes back with the same id (claude --resume) is still pinned: the
# service rounds that follow do not forget the pin of an ended clone.
id_resumed=12121212-cccc-4ccc-8ccc-121212121212
udarnik pin "$id_resumed" >/dev/null
sessions_tmp=$(mktemp)
jq --arg a "$account_a" --arg b "$account_b" --arg c "$id_resumed" \
  '. + [{original:"13131313-aaaa-4aaa-8aaa-131313131313", from:$a, clone:$c, to:$b, window:"c-13131313", window_id:"@gone", state:"ended", at:0}]' \
  "$UDARNIK_STATE/sessions.json" >"$sessions_tmp" && mv "$sessions_tmp" "$UDARNIK_STATE/sessions.json"
udarnik _serve --once >/dev/null 2>&1 || true
new_session "$account_a" "$id_resumed" "$project_root/sub2" ok; pid_resumed=$LAST_PID
assert_command 'move refuses a resumed clone of a pinned session: its record is ended, its pin stayed, nothing is closed' \
  bash -c 'jq -e --arg c "$1" "any(.[]; .clone == \$c and .state == \"ended\")" "$UDARNIK_STATE/sessions.json" >/dev/null && grep -qx "$1" "$UDARNIK_STATE/pinned"; code=0; out=$(udarnik move "${1:0:8}" --to peer 2>&1) || code=$?; [[ $code == 1 ]] && grep -q "session ${1:0:8} is pinned to here: it changes accounts here but never moves to another machine; nothing was closed" <<<"$out" && kill -0 "$2" && ! tmux -L "$3" list-windows -F "#{window_name}" | grep -qx "c-${1:0:8}"' _ "$id_resumed" "$pid_resumed" "$peer_socket"
kill "$pid_resumed" 2>/dev/null || true
udarnik unpin "$id_resumed" >/dev/null
id_peer_pinned=dddddddd-bbbb-4bbb-8bbb-dddddddddddd
HOME=$peer_home new_session "$peer_one" "$id_peer_pinned" "$peer_project/sub2" ok; pid_peer_pinned=$LAST_PID
peer udarnik pin "${id_peer_pinned:0:8}" --on peer >/dev/null
assert_command 'move --on refuses a pinned session of that machine too' \
  bash -c 'code=0; out=$(udarnik move "${1:0:8}" --on peer --to here 2>&1) || code=$?; [[ $code == 1 ]] && grep -q "is pinned to peer" <<<"$out" && kill -0 "$2"' _ "$id_peer_pinned" "$pid_peer_pinned"
kill "$pid_peer_pinned" 2>/dev/null || true
peer udarnik unpin "${id_peer_pinned:0:8}" >/dev/null
assert_command 'unpin lets it move again, and pins says when nothing is pinned' \
  bash -c 'udarnik unpin "${1:0:8}" | grep -q "no longer pinned" && ! udarnik unpin "${1:0:8}" | grep -q "no longer" && [[ $(udarnik pins) == "No session is pinned to here." ]]' _ "$id_pinned"
udarnik pin abcd1234 >/dev/null
udarnik pin abcd5678 >/dev/null
assert_command 'unpin removes only the pins the id starts with, never the pins that start with the id' \
  bash -c 'udarnik unpin abcd | grep -q "was not pinned" && [[ $(cat "$UDARNIK_STATE/pinned" | tr "\n" " ") == "abcd1234 abcd5678 " ]] && udarnik unpin abcd1234-aaaa | grep -q "no longer pinned" && [[ $(cat "$UDARNIK_STATE/pinned") == abcd5678 ]]'
udarnik unpin abcd5678 >/dev/null
kill "$pid_pinned" 2>/dev/null || true

# Takeover across machines: no account here has quota, the other machine has one, so the session goes there.
id_far=aaaaaaaa-cccc-4ccc-8ccc-aaaaaaaaaaaa
id_stay=eeeeeeee-bbbb-4bbb-8bbb-eeeeeeeeeeee
new_session "$account_a" "$id_far" "$project_root" limit; pid_far=$LAST_PID
new_session "$account_a" "$id_stay" "$project_root" limit; pid_stay=$LAST_PID
udarnik pin "${id_stay:0:8}" >/dev/null
accounts account_mark_out "$account_b" "$(future_text 1)" >/dev/null
accounts account_mark_out "$account_c" "$(future_text 1)" >/dev/null
: >"$UDARNIK_STATE/enabled"
UDARNIK_SHARE_WAIT=1 udarnik _serve --once >"$test_root/serve-fleet.out" 2>&1 || cat "$test_root/serve-fleet.out" >&2
assert_command 'takeover across machines: a pinned session stays here, waiting for an account here' \
  bash -c 'kill -0 "$1" && ! jq -e --arg id "$2" "any(.[]; .original == \$id)" "$UDARNIK_STATE/sessions.json" >/dev/null && grep -q "session eeeeeeee: account claude hit its limit and no other account is available here; the session is pinned to this machine, so it waits here" "$UDARNIK_STATE/udarnik.log"' _ "$pid_stay" "$id_stay"
kill "$pid_stay" 2>/dev/null || true
udarnik unpin "${id_stay:0:8}" >/dev/null
assert_command 'takeover across machines: with no account here, the limited session moved to the other machine' \
  bash -c '(! kill -0 "$1" 2>/dev/null || [[ $(awk "{print \$3}" /proc/$1/stat) == Z ]]) && jq -e --arg id "$2" "any(.[]; .original == \$id and .state == \"moved\" and .machine == \"peer\")" "$UDARNIK_STATE/sessions.json" >/dev/null' _ "$pid_far" "$id_far"
assert_command 'takeover across machines: the lines of the move reach the service journal' \
  bash -c 'grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ session ${2:0:8}: moving to peer " "$1" && grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^ ]+ session ${2:0:8}: moved to peer, clone " "$1"' \
  _ "$test_root/serve-fleet.out" "$id_far"
assert_command 'takeover across machines: it resumed there on the account that still has quota, saying why' \
  bash -c 'n=$(grep -lx "$1" "$2"/*.argv | head -1) && [[ $(cat "${n%.argv}.config") == "$3" ]] && tr "\n" " " <"$n" | grep -q "account claude hit its usage limit and no account on here has quota"' _ "$id_far" "$test_root/peer-calls" "$peer_z"
assert_command 'takeover across machines: the account at its limit here is out there too' \
  bash -c '[[ -s $1/accounts/claude.out-until ]] && ! peer bash -c "source \"\$1/lib/accounts.sh\"; account_available \"\$HOME/.claude\"" _ "$2"' _ "$peer_state" "$repo_root"
rm -f "$UDARNIK_STATE/enabled"

# Accounts that share one projects folder: the takeover copies nothing and no memory link is made.
shared_home="$test_root/shared-home"
mkdir -p "$shared_home/.claude-shared/projects/-p/memory" "$shared_home/a" "$shared_home/b" "$shared_home/c"
ln -s "$shared_home/.claude-shared/projects" "$shared_home/a/projects"
ln -s "$shared_home/.claude-shared/projects" "$shared_home/b/projects"
ln -s "$shared_home/.claude-shared/projects" "$shared_home/c/projects"
printf '%s\n' "$onboarded" >"$shared_home/a/.claude.json"
printf '%s\n' "$onboarded" >"$shared_home/b/.claude.json"
printf '{}\n' >"$shared_home/c/.claude.json"
assert_command 'shared projects folder: ensure_shared_links leaves it alone and logs nothing' \
  bash -c 'before=$(wc -l <"$UDARNIK_STATE/udarnik.log"); UDARNIK_ACCOUNTS="$1/a:$1/b" UDARNIK_SHARED_DIR="$1/.claude-shared" accounts ensure_shared_links; [[ $(wc -l <"$UDARNIK_STATE/udarnik.log") == "$before" && ! -L $1/.claude-shared/projects/-p/memory ]]' _ "$shared_home"
id_shared=bbbbbbbb-dddd-4ddd-8ddd-bbbbbbbbbbbb
rm -f "$UDARNIK_STATE"/accounts/*.out-until
new_session "$shared_home/a" "$id_shared" "$project_root" limit; pid_shared=$LAST_PID
: >"$UDARNIK_STATE/enabled"
# The only other account never opened Claude Code interactively: no clone, and the log says how to fix it.
UDARNIK_ACCOUNTS="$shared_home/a:$shared_home/c" UDARNIK_FLEET_TAKEOVER=off udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'a clone never starts in an account where Claude Code was never opened interactively' \
  bash -c 'kill -0 "$1" && ! grep -lqx "$2" "$3"/*.argv 2>/dev/null && grep -q "account c has quota but Claude Code was never opened interactively in it here" "$UDARNIK_STATE/udarnik.log"' _ "$pid_shared" "$id_shared" "$FAKE_CLAUDE_CALLS"
rm -f "$UDARNIK_STATE"/accounts/*.out-until
# The clone's account never trusted the folder: Claude Code asks, with "No, exit" selected, and the clone trusts it.
# (A new tmux server, so the clone sees the variable.)
tmux -L "$socket" kill-server 2>/dev/null || true
export FAKE_TRUST_FILE="$test_root/trusted"
UDARNIK_ACCOUNTS="$shared_home/a:$shared_home/b" UDARNIK_FLEET_TAKEOVER=off udarnik _serve --once >/dev/null 2>&1 || true
unset FAKE_TRUST_FILE
assert_command 'shared projects folder: the takeover resumes the fork from the same history, without copying it' \
  bash -c 'n=$(grep -lx "$1" "$2"/*.argv | head -1) && [[ $(cat "${n%.argv}.config") == "$3/b" ]] && [[ $(find "$3/.claude-shared/projects" -name "$1.jsonl*" | wc -l) == 1 ]]' _ "$id_shared" "$FAKE_CLAUDE_CALLS" "$shared_home"
assert_command 'a clone asked whether to trust its folder answers Yes and registers its session' \
  bash -c '[[ -e $1/trusted ]] && grep -q "clone of bbbbbbbb: trusted its folder" "$UDARNIK_STATE/udarnik.log" && jq -e "any(.[]; .original == \"$2\" and .clone != \"\")" "$UDARNIK_STATE/sessions.json" >/dev/null' _ "$test_root" "$id_shared"
rm -f "$UDARNIK_STATE/enabled"

# Headless sessions are workers: Claude Code 2.1.316 registers a claude -p as interactive with the entrypoint sdk-cli.
# One session of each entrypoint, all at their limit in account a (the only one with quota to leave to is b).
rm -f "$UDARNIK_STATE"/accounts/*.out-until
tmux -L "$socket" kill-server 2>/dev/null || true
id_sdkcli=cccccccc-1111-4111-8111-cccccccccccc
id_cli=cccccccc-2222-4222-8222-cccccccccccc
id_sdkts=cccccccc-3333-4333-8333-cccccccccccc
id_noep=cccccccc-4444-4444-8444-cccccccccccc
new_session "$shared_home/a" "$id_sdkcli" "$project_root" limit sdk-cli; pid_sdkcli=$LAST_PID
new_session "$shared_home/a" "$id_cli" "$project_root" limit cli; pid_cli=$LAST_PID
new_session "$shared_home/a" "$id_sdkts" "$project_root" limit sdk-ts; pid_sdkts=$LAST_PID
new_session "$shared_home/a" "$id_noep" "$project_root" limit; pid_noep=$LAST_PID
# A claude -p process that is also registered as sdk-cli, to be listed once.
CLAUDE_CONFIG_DIR="$shared_home/a" "$test_root/workerbin/claude" -I -c "$worker_code" -p 'registered too' >/dev/null 2>&1 & pid_both=$!
# The same, but /proc hides its environment: only the registry knows the account and the folder.
python3 -I -c 'import ctypes, time
libc = ctypes.CDLL(None)
libc.prctl(4, 0, 0, 0, 0)
libc.prctl(15, b"claude", 0, 0, 0)
time.sleep(300)' -p >/dev/null 2>&1 & pid_hidden_reg=$!
spawned="${spawned:-} $pid_both $pid_hidden_reg"
sleep 1
jq -cn --argjson pid "$pid_both" --arg cwd "$project_root" \
  '{pid:$pid, sessionId:"cccccccc-5555-4555-8555-cccccccccccc", cwd:$cwd, kind:"interactive", entrypoint:"sdk-cli"}' >"$shared_home/a/sessions/$pid_both.json"
jq -cn --argjson pid "$pid_hidden_reg" --arg cwd "$project_root" \
  '{pid:$pid, sessionId:"cccccccc-6666-4666-8666-cccccccccccc", cwd:$cwd, kind:"interactive", entrypoint:"sdk-cli"}' >"$shared_home/a/sessions/$pid_hidden_reg.json"
headless_status() { UDARNIK_ACCOUNTS="$shared_home/a:$shared_home/b" udarnik status --json; }
export shared_home
export -f headless_status
headless_status >"$test_root/status-headless.json"
assert_command 'headless: an sdk-cli session is not watched and is a worker with its account and folder' \
  jq_check --arg id "$id_sdkcli" --argjson pid "$pid_sdkcli" --arg account "$shared_home/a" --arg cwd "$project_root" \
    '(any(.sessions[]; .id == $id) | not) and ([.workers[] | select(.pid == $pid) | [.account, .cwd]] == [[$account, $cwd]])' "$test_root/status-headless.json"
assert_command 'headless: cli, sdk-ts and a session with no entrypoint are watched, not workers' \
  jq_check --arg cli "$id_cli" --arg ts "$id_sdkts" --arg none "$id_noep" --argjson pids "[$pid_cli, $pid_sdkts, $pid_noep]" \
    '([.sessions[] | select(.id == $cli or .id == $ts or .id == $none) | .state] == ["limit", "limit", "limit"]) and (any(.workers[]; .pid as $p | $pids | index($p)) | not)' "$test_root/status-headless.json"
assert_command 'headless: a process that ps and the registry both give is listed once, with its account' \
  jq_check --argjson pid "$pid_both" --arg account "$shared_home/a" '[.workers[] | select(.pid == $pid) | .account] == [$account]' "$test_root/status-headless.json"
assert_command 'headless: a process /proc hides, registered as sdk-cli, is listed once with the account and folder of the registry' \
  jq_check --argjson pid "$pid_hidden_reg" --arg account "$shared_home/a" --arg cwd "$project_root" '[.workers[] | select(.pid == $pid) | [.account, .cwd]] == [[$account, $cwd]]' "$test_root/status-headless.json"
assert_command 'headless: UDARNIK_HEADLESS_ENTRYPOINTS changes the list (cli is a worker, sdk-cli is watched again)' \
  bash -c 'UDARNIK_HEADLESS_ENTRYPOINTS="cli, sdk-py" headless_status >"$1" && jq -e --arg cli "$2" --arg sdkcli "$3" "(any(.sessions[]; .id == \$cli) | not) and any(.workers[]; .pid == $4) and any(.sessions[]; .id == \$sdkcli)" "$1" >/dev/null' _ "$test_root/status-headless2.json" "$id_cli" "$id_sdkcli" "$pid_cli"
assert_command 'headless: an empty list makes none of them a worker' \
  bash -c 'UDARNIK_HEADLESS_ENTRYPOINTS= headless_status | jq -e --arg id "$1" "any(.sessions[]; .id == \$id)" >/dev/null' _ "$id_sdkcli"
: >"$UDARNIK_STATE/enabled"
UDARNIK_ACCOUNTS="$shared_home/a:$shared_home/b" UDARNIK_FLEET_TAKEOVER=off udarnik _serve --once >/dev/null 2>&1 || true
rm -f "$UDARNIK_STATE/enabled"
assert_command 'headless: the sdk-cli session at its limit is not taken over: it keeps running and no clone resumes it' \
  bash -c 'kill -0 "$1" && ! grep -lqx "$2" "$3"/*.argv 2>/dev/null' _ "$pid_sdkcli" "$id_sdkcli" "$FAKE_CLAUDE_CALLS"
assert_command 'headless: cli and the session with no entrypoint at their limit are taken over' \
  bash -c 'for id in "$@"; do grep -lqx "$id" "$FAKE_CLAUDE_CALLS"/*.argv || exit 1; done' _ "$id_cli" "$id_noep"
assert_command 'headless: an sdk-ts session (an app hosts it) at its limit is watched but never closed or cloned' \
  bash -c 'kill -0 "$1" && ! grep -lqx "$2" "$3"/*.argv 2>/dev/null' _ "$pid_sdkts" "$id_sdkts" "$FAKE_CLAUDE_CALLS"
kill "$pid_sdkcli" "$pid_both" "$pid_hidden_reg" 2>/dev/null || true

# stop --all on the other machine, or on every machine, carries what it says and its exit status: a process it cannot
# end there makes the whole command fail, with the block of that machine saying which pid.
echo 'export UDARNIK_STOP_WAIT=0.4' >>"$test_root/hosts/peer-host.env"
bash -c "trap '' TERM; while :; do sleep 1; done" >/dev/null 2>&1 & stubborn_peer=$!
spawned="${spawned:-} $stubborn_peer"
mkdir -p "$peer_state/waits"
jq -cn --argjson pid "$stubborn_peer" --argjson start "$(sed -E 's/^.*\) //' "/proc/$stubborn_peer/stat" | awk '{ print $20 }')" \
  '{pid:$pid, start:$start, label:"stubborn", cwd:"/", since:1, until:2}' >"$peer_state/waits/$stubborn_peer.json"
assert_command 'status --fleet carries and renders the runners waiting for quota of each machine' \
  bash -c 'udarnik status --fleet --json | jq -e --argjson pid "$1" "[.machines[] | select(.name == \"peer\") | .status.waiting[] | select(.pid == \$pid) | .label] == [\"stubborn\"]" >/dev/null &&
    udarnik status --fleet | grep -qE "^  pid $1  until [0-9]{2}/[0-9]{2} [0-9]{2}:[0-9]{2}  stubborn  /$"' _ "$stubborn_peer"
rc=0; udarnik stop --all --on peer >"$test_root/stop-peer.out" 2>&1 || rc=$?
assert_command 'stop --all --on carries the exit status and the output of the other machine' \
  bash -c '[[ $1 == 1 ]] && grep -qx "Still alive: runner waiting for quota pid $2." "$3"' _ "$rc" "$stubborn_peer" "$test_root/stop-peer.out"
rc=0; udarnik stop --all --fleet >"$test_root/stop-fleet-all.out" 2>&1 || rc=$?
assert_command 'stop --all --fleet exits 1 when one machine cannot end something, and the other machines still answered' \
  bash -c '[[ $1 == 1 ]] && grep -qx "== here" "$3" && grep -qx "== peer" "$3" && grep -qx "Still alive: runner waiting for quota pid $2." "$3"' _ "$rc" "$stubborn_peer" "$test_root/stop-fleet-all.out"
kill -KILL "$stubborn_peer" 2>/dev/null || true
rm -f "$peer_state"/waits/*

tmux -L "$socket" kill-server 2>/dev/null || true
tmux -L "$peer_socket" kill-server 2>/dev/null || true
unset UDARNIK_MACHINE_ID UDARNIK_SHARE_WAIT
export UDARNIK_FLEET="$test_root/no-fleet.json" UDARNIK_SSH=false
export UDARNIK_STATE=$saved_state UDARNIK_ACCOUNTS=$saved_accounts FAKE_CLAUDE_CALLS=$saved_calls

# ---------------------------------------------------------------- install.sh

rm -f "$FAKE_SYSTEMD_ACTIVE"
install_env() { # <home> <accounts> [shared dir]: runs install.sh with a temporary HOME
  local home=$1 accounts=$2 shared=${3:-$1/.claude-shared}
  shift 3 || shift $#
  HOME="$home" UDARNIK_PREFIX="$home/prefix" UDARNIK_ACCOUNTS="$accounts" UDARNIK_SHARED_DIR="$shared" "$repo_root/install.sh" "$@"
}
export -f install_env

# 1. No shared folder: the skill is copied into every account, with the marker, and the command link works.
home1="$test_root/h1"
mkdir -p "$home1/.claude" "$home1/.claude-b"
install_env "$home1" "$home1/.claude:$home1/.claude-b" >"$test_root/install1.out" 2>&1 || { cat "$test_root/install1.out" >&2; true; }
assert_command 'install without a shared folder copies the skill into every account with the marker' \
  bash -c 'for a in "$1/.claude" "$1/.claude-b"; do [[ -d $a/skills/takeover && ! -L $a/skills/takeover && -f $a/skills/takeover/SKILL.md && -f $a/skills/takeover/.udarnik ]] || exit 1; done; cmp "$2/skills/takeover/SKILL.md" "$1/.claude/skills/takeover/SKILL.md"' _ "$home1" "$repo_root"
assert_command 'install copies the tree to the prefix and the link in ~/.local/bin works' \
  bash -c '[[ -x $1/prefix/bin/udarnik && -f $1/prefix/lib/accounts.sh && -f $1/prefix/lib/session_probe.py && -f $1/prefix/skills/takeover/SKILL.md && $(readlink "$1/.local/bin/udarnik") == "$1/prefix/bin/udarnik" ]] && "$1/.local/bin/udarnik" help | grep -q "^Usage: udarnik"' _ "$home1"
install_env "$home1" "$home1/.claude:$home1/.claude-b" >/dev/null 2>&1
assert_command 'install is an update when run again' \
  bash -c '[[ -f $1/.claude/skills/takeover/.udarnik && -x $1/prefix/bin/udarnik && ! -e $1/prefix.staging ]]' _ "$home1"

# 2. A foreign skills/takeover (real folder or foreign symlink) is never touched without --force.
home2="$test_root/h2"
mkdir -p "$home2/.claude" "$home2/.claude-b" "$home2/.claude-c" "$home2/.claude-d" "$home2/foreign-skill" "$home2/.claude-b/skills/takeover" "$home2/.claude-c/skills"
printf 'mine\n' >"$home2/.claude-b/skills/takeover/own.txt"
printf 'mine\n' >"$home2/foreign-skill/own.txt"
ln -s "$home2/foreign-skill" "$home2/.claude-c/skills/takeover"
accounts2="$home2/.claude:$home2/.claude-b:$home2/.claude-c:$home2/.claude-d"
install_env "$home2" "$accounts2" >"$test_root/install2.out" 2>&1 || { cat "$test_root/install2.out" >&2; true; }
assert_command 'install leaves a foreign skills/takeover (real folder or symlink) untouched and says so' \
  bash -c '[[ -f $1/.claude-b/skills/takeover/own.txt && ! -e $1/.claude-b/skills/takeover/.udarnik && ! -e $1/.claude-b/skills/takeover/SKILL.md && $(readlink "$1/.claude-c/skills/takeover") == "$1/foreign-skill" && ! -e $1/foreign-skill/.udarnik && -f $1/.claude/skills/takeover/.udarnik && -f $1/.claude-d/skills/takeover/.udarnik ]] && grep -q "skipped: $1/.claude-b/skills/takeover" "$2" && grep -q "skipped: $1/.claude-c/skills/takeover" "$2"' _ "$home2" "$test_root/install2.out"

# 3. --uninstall removes only what carries the marker.
install_env "$home2" "$accounts2" /dev/null --uninstall >"$test_root/uninstall2.out" 2>&1 || { cat "$test_root/uninstall2.out" >&2; true; }
assert_command 'uninstall removes the marked skill copies, the link and the tree, and keeps foreign things and the state' \
  bash -c '[[ ! -e $1/.claude/skills/takeover && ! -e $1/.claude-d/skills/takeover && ! -e $1/prefix && ! -e $1/.local/bin/udarnik && -f $1/.claude-b/skills/takeover/own.txt && $(readlink "$1/.claude-c/skills/takeover") == "$1/foreign-skill" && -f $1/foreign-skill/own.txt && -d "$UDARNIK_STATE" ]] && grep -q "state directory was kept: $UDARNIK_STATE" "$2"' _ "$home2" "$test_root/uninstall2.out"

# 4. --force replaces a foreign skills/takeover.
install_env "$home2" "$accounts2" '' --force >/dev/null 2>&1 || true
assert_command 'install --force replaces a foreign skills/takeover' \
  bash -c '[[ -f $1/.claude-b/skills/takeover/.udarnik && -f $1/.claude-b/skills/takeover/SKILL.md && ! -e $1/.claude-b/skills/takeover/own.txt && -f $1/.claude-c/skills/takeover/.udarnik && -f $1/foreign-skill/own.txt ]]' _ "$home2"

# 5. With a shared folder the skill lives there and the accounts get symlinks.
home3="$test_root/h3"
mkdir -p "$home3/.claude" "$home3/.claude-b" "$home3/shared/skills/other"
accounts3="$home3/.claude:$home3/.claude-b"
install_env "$home3" "$accounts3" "$home3/shared" >"$test_root/install3.out" 2>&1 || { cat "$test_root/install3.out" >&2; true; }
assert_command 'install with a shared folder puts the skill there and symlinks every account to it' \
  bash -c '[[ -f $1/shared/skills/takeover/SKILL.md && -f $1/shared/skills/takeover/.udarnik && $(readlink "$1/.claude/skills/takeover") == "$1/shared/skills/takeover" && $(readlink "$1/.claude-b/skills/takeover") == "$1/shared/skills/takeover" && -f $1/.claude-b/skills/takeover/SKILL.md ]]' _ "$home3"
install_env "$home3" "$accounts3" "$home3/shared" >/dev/null 2>&1
assert_command 'install with a shared folder is idempotent and keeps the other shared skills' \
  bash -c '[[ $(readlink "$1/.claude/skills/takeover") == "$1/shared/skills/takeover" && -d $1/shared/skills/other ]]' _ "$home3"
install_env "$home3" "$accounts3" "$home3/shared" --uninstall >/dev/null 2>&1 || true
assert_command 'uninstall removes the shared skill and the account links but not the shared folder' \
  bash -c '[[ ! -e $1/shared/skills/takeover && ! -L $1/.claude/skills/takeover && ! -L $1/.claude-b/skills/takeover && -d $1/shared/skills/other && ! -e $1/prefix ]]' _ "$home3"

# 6. A foreign shared skills/takeover blocks the shared install.
home4="$test_root/h4"
mkdir -p "$home4/.claude" "$home4/shared/skills/takeover"
printf 'mine\n' >"$home4/shared/skills/takeover/own.txt"
install_env "$home4" "$home4/.claude" "$home4/shared" >"$test_root/install4.out" 2>&1 || true
assert_command 'a foreign shared skills/takeover is not touched and no account is linked to it' \
  bash -c '[[ -f $1/shared/skills/takeover/own.txt && ! -e $1/shared/skills/takeover/.udarnik && ! -e $1/.claude/skills/takeover ]] && grep -q "skipped: $1/shared/skills/takeover" "$2"' _ "$home4" "$test_root/install4.out"

# 7. A running service keeps the old version; install never restarts it and uninstall never uses --all.
touch "$FAKE_SYSTEMD_ACTIVE"
install_env "$home1" "$home1/.claude" >"$test_root/install5.out" 2>&1 || true
assert_command 'install with the service active says it keeps the old version until stop --all and start' \
  bash -c 'grep -q "keeps the old version until: udarnik stop --all, then udarnik start" "$1" && [[ -e $FAKE_SYSTEMD_ACTIVE ]]' _ "$test_root/install5.out"
rm -f "$UDARNIK_STATE/runners"
: >"$UDARNIK_STATE/enabled"
install_env "$home1" "$home1/.claude" /dev/null --uninstall >"$test_root/uninstall5.out" 2>&1 || true
assert_command 'uninstall with the service active only turns the switch off (stop, never --all)' \
  bash -c '[[ -e $FAKE_SYSTEMD_ACTIVE && ! -e $UDARNIK_STATE/enabled ]] && grep -q "stop: switch off" "$UDARNIK_STATE/udarnik.log" && ! grep -q "stop --all" "$UDARNIK_STATE/udarnik.log"'
assert_command 'uninstall turns the hook for runners off, even the one the stop of an older switch kept on, and says so' \
  bash -c '[[ $(cat "$UDARNIK_STATE/runners") == off ]] && ! "$2/bin/udarnik" account enabled && grep -q "account switching for runners turned off" "$1"' _ "$test_root/uninstall5.out" "$repo_root"
rm -f "$FAKE_SYSTEMD_ACTIVE"

# 8. Missing requirements fail with a clear message.
mkdir -p "$test_root/nojq"
for tool in bash env dirname readlink mkdir cp printf rm ls cat ln mv sed; do ln -sf "$(command -v "$tool")" "$test_root/nojq/$tool"; done
assert_command 'install fails with a clear message when a requirement is missing' \
  bash -c 'out=$(PATH="$1/nojq" HOME="$2" UDARNIK_PREFIX="$2/prefix" /usr/bin/env bash "$3/install.sh" 2>&1) || true; grep -q "missing requirement" <<<"$out" && [[ ! -e $2/prefix ]]' _ "$test_root" "$test_root/h5" "$repo_root"

printf '1..%s\n' "$((passed + failed))"
(( failed == 0 ))
