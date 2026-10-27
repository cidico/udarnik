#!/usr/bin/env bash
# Deterministic tests of lib/accounts.sh, bin/udarnik and install.sh. Never touches a real account, real state, a
# real session or a real service: HOME, the account directories and the state directory are temporary, `claude` is
# a fake, tmux has its own socket, and systemctl/systemd-run are stubs. Run: bash tests/udarnik.sh

set -euo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d)
socket="udarnik-test-$$"
export HOME="$test_root/home"
export UDARNIK_STATE="$test_root/state"
export UDARNIK_TMUX_SOCKET=$socket
# Never the real service: the unit is unique and systemctl/systemd-run are stubs.
export UDARNIK_UNIT="udarnik-test-$$"
export UDARNIK_CLONE_SCOPE=off
export UDARNIK_CLONE_WAIT_SECONDS=20
export UDARNIK_SHARED_DIR="$HOME/.claude-shared"
unset CLAUDE_CONFIG_DIR UDARNIK_ROOT UDARNIK_USAGE_FILE UDARNIK_TERMINAL UDARNIK_CLAUDE UDARNIK_LINKS UDARNIK_PREFIX
project_root="$test_root/project"
mkdir -p "$HOME/.cache" "$project_root/sub" "$test_root/bin"
cd "$test_root"

cleanup() {
  local p
  tmux -L "$socket" kill-server 2>/dev/null || true
  for p in ${spawned:-}; do pkill -P "$p" 2>/dev/null || true; kill "$p" 2>/dev/null || true; done
  rm -rf -- "$test_root"
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
cat >"$test_root/fake-systemd/systemd-run" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$FAKE_SYSTEMD_LOG"
touch "$FAKE_SYSTEMD_ACTIVE"
FAKE
cat >"$test_root/fake-systemd/systemctl" <<'FAKE'
#!/usr/bin/env bash
if [[ " $* " == *" is-active "* ]]; then [[ -e $FAKE_SYSTEMD_ACTIVE ]]; exit; fi
if [[ " $* " == *" stop "* ]]; then rm -f "$FAKE_SYSTEMD_ACTIVE"; exit 0; fi
exit 0
FAKE
chmod +x "$test_root/fake-systemd/"*
export FAKE_SYSTEMD_LOG="$test_root/systemd.log" FAKE_SYSTEMD_ACTIVE="$test_root/systemd.active"
export PATH="$test_root/fake-systemd:$PATH"

accounts() { source "$repo_root/lib/accounts.sh"; "$@"; }
udarnik() { "$repo_root/bin/udarnik" "$@"; }
export -f accounts udarnik
export repo_root

usage_cache() { # <key> <weekly percent> <resets_at>
  jq -cn --argjson percent "$2" --arg reset "${3:-}" \
    '{limits:[{kind:"weekly_all", percent:$percent, resets_at:(if $reset == "" then null else $reset end)}]}' >"$HOME/.cache/claude-statusline-usage-$1.json"
}

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
assert_command 'mark_out falls back to the weekly reset in the usage file' \
  bash -c '[[ $(cat "$UDARNIK_STATE/accounts/claude-b.out-until") == "$(date -d "$1" +%s)" ]]' _ "$cache_reset"

accounts account_mark_out "$account_c" "unreadable" >/dev/null
assert_command 'mark_out without a usage file falls back to one hour from now' \
  bash -c 'v=$(cat "$UDARNIK_STATE/accounts/claude-c.out-until"); now=$(date +%s); (( v >= now + 3590 && v <= now + 3610 ))'

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
rm -f "$UDARNIK_STATE/enabled"
assert_command 'account enabled fails while the switch is off and succeeds while it is on' \
  bash -c '! udarnik account enabled && : >"$UDARNIK_STATE/enabled" && udarnik account enabled'
usage_cache claude 70 ""
usage_cache claude-b 20 ""
assert_command 'account current is the caller account when it is available' \
  bash -c '[[ $(udarnik account current) == "$1" && $(CLAUDE_CONFIG_DIR="$2" udarnik account current) == "$2" ]]' _ "$account_a" "$account_b"
accounts account_mark_out "$account_a" "$(future_text 1)" >/dev/null
assert_command 'account current moves a caller whose account is out to the best available one' \
  bash -c '[[ $(udarnik account current) == "$1" ]]' _ "$account_b"
assert_command 'account current keeps the caller account when the switch is off' \
  bash -c 'rm -f "$UDARNIK_STATE/enabled"; r=0; [[ $(udarnik account current) == "$1" ]] || r=1; : >"$UDARNIK_STATE/enabled"; exit $r' _ "$account_a"
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
rm -f "$UDARNIK_STATE"/accounts/*.out-until "$UDARNIK_STATE/enabled" "$UDARNIK_STATE/udarnik.log"

# ---------------------------------------------------------------- bin/udarnik, one loop with everything fake

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
resume=''
while (($#)); do
  if [[ $1 == --resume ]]; then resume=$2; fi
  shift
done
new=$(python3 -c 'import uuid; print(uuid.uuid4())')
slug=$(sed -E 's/[^A-Za-z0-9]/-/g' <<<"$PWD")
mkdir -p "$config/projects/$slug" "$config/sessions"
cp "$config/projects/$slug/$resume.jsonl" "$config/projects/$slug/$new.jsonl"
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

# new_session <account> <id> <cwd> <last entry: ok|limit|stale>: a live "interactive session" (a sleep) with a history.
new_session() {
  local account=$1 id=$2 cwd=$3 kind=$4 slug history started stamp
  slug=$(slug_of "$cwd")
  history="$account/projects/$slug/$id.jsonl"
  mkdir -p "$account/sessions" "$account/projects/$slug/$id/subagents" "$cwd"
  sleep 300 &
  local pid=$!
  spawned="${spawned:-} $pid"
  started=$(( ($(date +%s) - 120) * 1000 ))
  jq -cn --argjson pid "$pid" --arg id "$id" --arg cwd "$cwd" --argjson started "$started" \
    '{pid:$pid, sessionId:$id, cwd:$cwd, kind:"interactive", startedAt:$started, updatedAt:$started}' >"$account/sessions/$pid.json"
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
usage_cache claude 90 ""
usage_cache claude-b 10 ""
usage_cache claude-c 50 ""

jq_check() { jq -e "$@" >/dev/null; }
alive() { kill -0 "$1" 2>/dev/null && [[ $(awk '{print $3}' "/proc/$1/stat") != Z ]]; }

# Switch off: nothing is touched.
udarnik _serve --once >/dev/null
assert_command 'with the switch off a limited session is left alone' alive "$pid_limit"

mkdir -p "$UDARNIK_STATE"
: >"$UDARNIK_STATE/enabled"
printf 'zzzzzzzz\n' >"$UDARNIK_STATE/only"
printf '%s\n' "$project_root" >"$UDARNIK_STATE/root"
udarnik _serve --once >/dev/null
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

udarnik _serve --once >"$test_root/serve1.out" 2>&1 || { cat "$test_root/serve1.out" >&2; true; }
sleep 1
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

# The clone is watched like any session; its copied history still ends in the old error, which must not chain it.
sleep 1
udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'the old error inside the forked history does not take the clone over again' \
  bash -c '[[ $(find "$1" -name "*.argv" | wc -l) == 1 ]]' _ "$FAKE_CLAUDE_CALLS"

udarnik status --json >"$test_root/status.json"
status_check() { jq -e "$@" "$test_root/status.json" >/dev/null; }
assert_command 'status --json: the service, the switch, the context, the root and the accounts'   status_check --arg root "$project_root" '.service.active == false and .enabled == true and .context == "the owner note" and .root == $root and (.accounts | length) == 3 and ([.accounts[] | select(.key == "claude") | .available] == [false]) and ([.accounts[] | select(.key == "claude-b") | .weekly_percent] == [10])'
assert_command 'status --json: the live clone with its original and window'   status_check '(.clones | length) == 1 and .clones[0].alive == true and .clones[0].original == "'"$id_limit"'" and .clones[0].window == "c-11111111"'
assert_command 'status --json: watched sessions carry pid, short id, state and the title of the first request'   status_check '([.sessions[] | select(.short == "22222222")] | length) == 1 and ([.sessions[] | select(.short == "22222222") | .state] == ["ok"]) and ([.sessions[] | select(.title == "please fix the thing in the checkout")] | length) >= 1 and ([.sessions[] | select(.short == "33333333") | .state] == ["ok"])'
assert_command 'status prints a readable board'   bash -c 'out=$(udarnik status); grep -q "Accounts" <<<"$out" && grep -q "Clones" <<<"$out" && grep -q "c-11111111" <<<"$out" && grep -q "^Root: " <<<"$out"'
assert_command 'status --json: every tmux window with the session it runs and the attach command'   status_check --arg c "$clone_one" '.view.attach == "tmux -L '"$socket"' attach -t udarnik" and ([.view.windows[] | select(.name == "c-11111111") | [.alive, .session]] == [[true, $c]])'
assert_command 'status ends with how to see the sessions'   bash -c 'udarnik status | tail -1 | grep -q "udarnik view"'

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
udarnik _serve --once >"$test_root/serve2.out" 2>&1 || { cat "$test_root/serve2.out" >&2; true; }
sleep 1
assert_command 'chain: the first clone was closed and a second one started in the third account' \
  bash -c '! kill -0 "$1" 2>/dev/null || [[ $(awk "{print \$3}" /proc/$1/stat) == Z ]]; [[ $(find "$2" -name "*.argv" | wc -l) == 2 && $(cat "$2/2.config") == "$3" ]] && grep -qx -- "$4" "$2/2.argv"' _ "$clone_pid" "$FAKE_CLAUDE_CALLS" "$account_c" "$clone_one"
assert_command 'chain: both earlier accounts are out and sessions.json links the whole chain' \
  bash -c '! accounts account_available "$1" && ! accounts account_available "$2" && jq -e --arg a "$3" --arg b "$4" "length == 2 and .[1].original == \$a and .[1].to == \"$5\"" "$UDARNIK_STATE/sessions.json" >/dev/null' _ "$account_a" "$account_b" "$clone_one" "x" "$account_c"

# With every account out nothing is taken over and nothing is closed.
clone_two=$(cat "$FAKE_CLAUDE_CALLS/2.session")
accounts account_mark_out "$account_c" "$(future_text 2)" >/dev/null
sleep 2
clone_two_pid=$(jq -r --arg id "$clone_two" 'select(.sessionId == $id) | .pid' "$account_c"/sessions/*.json)
jq -cn --arg id "$clone_two" --arg ts "$(iso_now)" --arg text "$(future_text 2)" \
  '{type:"assistant", sessionId:$id, timestamp:$ts, isApiErrorMessage:true, error:"rate_limit", message:{model:"<synthetic>", role:"assistant", content:[{type:"text", text:$text}]}}' \
  >>"$account_c/projects/$slug/$clone_two.jsonl"
udarnik _serve --once >/dev/null 2>&1 || true
assert_command 'with no account left the session is kept running and the log says so' \
  bash -c 'kill -0 "$1" && ! grep -q "ATTENTION" "$2/udarnik.log" && grep -q "no other account is available" "$2/udarnik.log"' _ "$clone_two_pid" "$UDARNIK_STATE"

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

# start with the fake systemd: one transient service from a snapshot, nothing else.
rm -rf "$UDARNIK_STATE" "$FAKE_SYSTEMD_LOG" "$FAKE_SYSTEMD_ACTIVE"
UDARNIK_LINKS=off TZ=Europe/Lisbon udarnik start --context "note" --only abc,def --root "$project_root/sub/../" >/dev/null
assert_command 'start turns the switch on, stores context, filter and root, and starts one transient service from a snapshot' \
  bash -c '[[ -f "$1/enabled" && $(cat "$1/context") == note && $(cat "$1/only") == $(printf "abc\ndef") && $(cat "$1/root") == "$3" && -x "$1/snapshot/bin/udarnik" ]] && grep -qx -- "--unit=$UDARNIK_UNIT" "$2" && grep -qx -- "--collect" "$2" && grep -qx "$1/snapshot/bin/udarnik" "$2" && tail -1 "$2" | grep -qx "_serve" && grep -qx -- "--setenv=UDARNIK_STATE=$1" "$2"' _ "$UDARNIK_STATE" "$FAKE_SYSTEMD_LOG" "$project_root"
assert_command 'start gives the unit its description and passes PATH, HOME, TZ and every UDARNIK_ variable' \
  bash -c 'grep -qx -- "--description=udarnik: Claude account takeover" "$1" && grep -qE -- "^--setenv=PATH=(.*:)?$HOME/\.local/bin(:.*)?$" "$1" &&grep -qx -- "--setenv=HOME=$HOME" "$1" && grep -qx -- "--setenv=TZ=Europe/Lisbon" "$1" && grep -qx -- "--setenv=UDARNIK_UNIT=$UDARNIK_UNIT" "$1" && grep -qx -- "--setenv=UDARNIK_TMUX_SOCKET=$2" "$1" && grep -qx -- "--setenv=UDARNIK_CLONE_SCOPE=off" "$1" && grep -qx -- "--setenv=UDARNIK_LINKS=off" "$1"' _ "$FAKE_SYSTEMD_LOG" "$socket"
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
udarnik stop >/dev/null
assert_command 'stop turns the switch off and leaves the service to exit on its own' \
  bash -c '[[ ! -e "$1/enabled" && -e "$2" ]]' _ "$UDARNIK_STATE" "$FAKE_SYSTEMD_ACTIVE"

# Started from the snapshot itself, start reuses it instead of copying again.
rm -f "$FAKE_SYSTEMD_ACTIVE" "$FAKE_SYSTEMD_LOG"
snapshot_inode=$(stat -c %i "$UDARNIK_STATE/snapshot")
UDARNIK_LINKS=off "$UDARNIK_STATE/snapshot/bin/udarnik" start >/dev/null
assert_command 'start run from the snapshot reuses it' \
  bash -c '[[ $(stat -c %i "$1/snapshot") == "$2" ]] && tail -2 "$3" | head -1 | grep -qx "$1/snapshot/bin/udarnik"' _ "$UDARNIK_STATE" "$snapshot_inode" "$FAKE_SYSTEMD_LOG"
udarnik stop >/dev/null

# A service with the switch off and no clone leaves by itself.
timeout 20 "$repo_root/bin/udarnik" _serve >/dev/null 2>&1 && pass 'the service exits when the switch is off and no clone is alive' || fail 'the service exits when the switch is off and no clone is alive'

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
install_env "$home1" "$home1/.claude" /dev/null --uninstall >/dev/null 2>&1 || true
assert_command 'uninstall with the service active only turns the switch off (stop, never --all)' \
  bash -c '[[ -e $FAKE_SYSTEMD_ACTIVE && ! -e $UDARNIK_STATE/enabled ]] && grep -q "stop: switch off" "$UDARNIK_STATE/udarnik.log" && ! grep -q "stop --all" "$UDARNIK_STATE/udarnik.log"'
rm -f "$FAKE_SYSTEMD_ACTIVE"

# 8. Missing requirements fail with a clear message.
mkdir -p "$test_root/nojq"
for tool in bash env dirname readlink mkdir cp printf rm ls cat ln mv sed; do ln -sf "$(command -v "$tool")" "$test_root/nojq/$tool"; done
assert_command 'install fails with a clear message when a requirement is missing' \
  bash -c 'out=$(PATH="$1/nojq" HOME="$2" UDARNIK_PREFIX="$2/prefix" /usr/bin/env bash "$3/install.sh" 2>&1) || true; grep -q "missing requirement" <<<"$out" && [[ ! -e $2/prefix ]]' _ "$test_root" "$test_root/h5" "$repo_root"

printf '1..%s\n' "$((passed + failed))"
(( failed == 0 ))
