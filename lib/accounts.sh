#!/usr/bin/env bash
# Claude account logic shared by bin/udarnik and by any runner that wants the same failover. Sourced, never executed.
#
# State lives in ${UDARNIK_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/udarnik}:
#   enabled                      switch of the interactive takeover: it works only while this file exists
#   runners                      switch of the account hook for runners: "on" or "off"; absent is off, unless an
#                                `enabled` of a version without this file exists (it counts as on)
#   accounts/<key>.out-until     epoch until which an account is out of quota
#   accounts/<key>.out-news      "AT [FROM]" of that epoch: when it was learned and from which machine (none: here)
#                                (both files go away when a call works in the account: see _clear_out_until)
#   accounts/<key>.back-at       epoch of the newest call that worked in the account (a clear, here or told by another
#                                machine): an "out" news not newer than it is rejected
#   accounts/<key>.weekly        the newest weekly usage known: {percent, resets_at, at, from} (from "": here)
#   accounts/<key>.weekly-shared the last weekly usage of this machine told to the others: {percent, at}
#   order.<kind>                 preference order of the accounts for a kind of caller (one account key per line)
#   waits/<pid>.json             a runner waiting for quota (udarnik account wait): pid, start, label, cwd, since, until
#   pinned                       session id prefixes that never move to another machine (one per line)
#   kept.json                    kept sessions the service brings back when their process dies: id, account, cwd, pid,
#                                start, scope (its systemd scope, when it has a dedicated one), window_id, resumes
#   sessions.json                interactive sessions taken over (written by bin/udarnik)
#   context                      owner note appended to the takeover message
#   only                         session id prefixes the takeover is limited to (one per line)
#   root                         directory the takeover is limited to (sessions at or below it)
#   udarnik.log                  the single log
# Every write happens under flock. <key> is the account directory name without its leading dot.
# Nothing here ever touches the network: the weekly usage is only read from a file a statusline keeps.

udarnik_state_dir() { printf '%s\n' "${UDARNIK_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/udarnik}"; }

udarnik_enabled() { [[ -f "$(udarnik_state_dir)/enabled" ]]; }

# The account hook for runners is on while the runners file says "on". Never on by default: without the file it is
# off, except when the takeover switch of a version before this file is on (it covered the runners too).
udarnik_runners_enabled() {
  local dir
  dir=$(udarnik_state_dir)
  if [[ -f $dir/runners ]]; then
    [[ $(tr -d '[:space:]' <"$dir/runners" 2>/dev/null) == on ]]
  else
    [[ -f $dir/enabled ]]
  fi
}

_write_runners() { # on|off, whole: a reader never sees half a file
  local dir
  dir=$(udarnik_state_dir)
  printf '%s\n' "$1" >"$dir/runners.new" && mv -f -- "$dir/runners.new" "$dir/runners"
}
# Turns the account hook for runners on or off, under the runners lock.
udarnik_set_runners() { state_locked runners _write_runners "$1"; }

# Runs a command (function or program) while holding the named state lock.
state_locked() {
  local name=$1 dir
  shift
  dir=$(udarnik_state_dir)
  (umask 077; mkdir -p -- "$dir/accounts")
  ( flock -x 9; "$@" ) 9>"$dir/.$name.lock"
}

_append_log_line() { printf '%s\n' "$1" >>"$(udarnik_state_dir)/udarnik.log"; }

# One line in udarnik.log; also on stderr when the shell variable UDARNIK_LOG_JOURNAL is 1 (the service sets it, for
# its journal). Never on stdout: a function whose output is read with $(...) (an epoch, a clone's id) logs too, and
# the line would become part of the value.
udarnik_log() {
  local line
  line="$(date -Is) $*"
  state_locked log _append_log_line "$line"
  [[ ${UDARNIK_LOG_JOURNAL:-0} != 1 ]] || printf '%s\n' "$line" >&2
  return 0
}

account_key() {
  local name
  name=$(basename -- "${1%/}")
  printf '%s\n' "${name#.}"
}

_shared_dir() { printf '%s\n' "${UDARNIK_SHARED_DIR:-$HOME/.claude-shared}"; }

# Every account directory that can run Claude: ~/.claude plus ~/.claude-*, never the shared folder.
accounts_list() {
  local directory shared
  shared=$(_shared_dir)
  shared=${shared%/}
  if [[ -n ${UDARNIK_ACCOUNTS:-} ]]; then
    while IFS= read -r directory; do
      [[ -n $directory && ${directory%/} != "$shared" ]] && printf '%s\n' "${directory%/}"
    done < <(tr ':' '\n' <<<"$UDARNIK_ACCOUNTS")
    return 0
  fi
  for directory in "$HOME/.claude" "$HOME"/.claude-*; do
    [[ -d $directory && -f $directory/.credentials.json ]] || continue
    [[ $directory == "$shared" || $(basename -- "$directory") == .claude-shared ]] && continue
    printf '%s\n' "$directory"
  done
}

# The account of the current environment: CLAUDE_CONFIG_DIR, or ~/.claude when it is empty or unset.
account_of_env() {
  local directory=${CLAUDE_CONFIG_DIR:-}
  [[ -n $directory ]] || directory="$HOME/.claude"
  printf '%s\n' "${directory%/}"
}

# The env prefix that runs a command in the account (~/.claude is the one without CLAUDE_CONFIG_DIR).
account_env() {
  local account=${1%/}
  if [[ $account == "$HOME/.claude" ]]; then
    printf 'env -u CLAUDE_CONFIG_DIR\n'
  else
    printf 'env CLAUDE_CONFIG_DIR=%q\n' "$account"
  fi
}

_out_until_file() { printf '%s/accounts/%s.out-until\n' "$(udarnik_state_dir)" "$(account_key "$1")"; }

# Epoch until which the account is out; 0 when it is not.
account_out_until() {
  local file value
  file=$(_out_until_file "$1")
  value=$(cat -- "$file" 2>/dev/null || true)
  [[ $value =~ ^[0-9]+$ ]] || value=0
  printf '%s\n' "$value"
}

# "AT FROM" of the account's out-until: when that news was learned and the machine it came from (empty: this one).
# Prints nothing when unknown (an out-until written by an older version).
account_out_news() {
  local file at='' from=''
  file=$(_out_until_file "$1")
  # IFS of its own: bin/udarnik splits words on newlines and tabs only.
  IFS=' ' read -r at from 2>/dev/null <"${file%.out-until}.out-news" || true
  [[ $at =~ ^[0-9]+$ ]] || return 0
  printf '%s %s\n' "$at" "$from"
}

account_available() {
  (( $(account_out_until "$1") <= $(date +%s) ))
}

# The epoch at which the first account is available again: now when one already is.
accounts_next_available_epoch() {
  local account until earliest='' now
  while IFS= read -r account; do
    [[ -n $account ]] || continue
    until=$(account_out_until "$account")
    if [[ -z $earliest ]] || ((until < earliest)); then earliest=$until; fi
  done < <(accounts_list)
  now=$(date +%s)
  if [[ -z $earliest ]] || ((earliest <= now)); then earliest=$now; fi
  printf '%s\n' "$earliest"
}

# The file that holds a copy of the account's /api/oauth/usage response: UDARNIK_USAGE_FILE with {key} replaced by the
# account key. Whoever keeps that copy (a statusline) makes the call; this code only reads the file.
_usage_cache_file() {
  local template=${UDARNIK_USAGE_FILE:-$HOME/.cache/claude-statusline-usage-\{key\}.json} key
  key=$(account_key "$1")
  printf '%s\n' "${template//'{key}'/"$key"}"
}

_weekly_file() { printf '%s/accounts/%s.weekly\n' "$(udarnik_state_dir)" "$(account_key "$1")"; }

# The weekly usage this machine reads in the usage file, as {percent, resets_at, at, from:""}, "at" being the time of
# the file; empty when unknown.
_cache_weekly() {
  local file
  file=$(_usage_cache_file "$1")
  [[ -f $file ]] || return 0
  jq -c --argjson at "$(stat -c %Y -- "$file")" '[.limits[]? | select(.kind == "weekly_all")][0] // empty
    | select((.percent | type) == "number") | {percent, resets_at:(.resets_at // null), at:$at, from:""}' "$file" 2>/dev/null || true
}

_stored_weekly() {
  jq -c 'select(type == "object" and (.percent | type) == "number" and (.at | type) == "number")' "$1" 2>/dev/null || true
}

# The newest weekly usage known for the account: what this machine reads in its usage file or what another machine
# told (accounts/<key>.weekly), whichever is newer. One JSON object {percent, resets_at, at, from}, "from" being the
# machine it came from ("" for this one); empty when unknown.
account_weekly() {
  local cached stored
  cached=$(_cache_weekly "$1")
  stored=$(_stored_weekly "$(_weekly_file "$1")")
  [[ -n $cached || -n $stored ]] || return 0
  # On a tie the reading of this machine wins (max_by keeps the last of the maxima).
  jq -cn --argjson stored "${stored:-null}" --argjson cached "${cached:-null}" \
    '[$stored, $cached] | map(select(. != null)) | max_by(.at)'
}

# Weekly percentage, the newest known; empty when unknown.
account_weekly_percent() {
  local weekly
  weekly=$(account_weekly "$1")
  [[ -n $weekly ]] || return 0
  jq -r '.percent // empty' <<<"$weekly"
}

# _weekly_observe ACCOUNT [share]: stores what this machine reads in the usage file when it is newer than the weekly
# usage known. With "share", prints that reading and succeeds when the other machines should be told: it is the
# newest known, it changed since they were last told, and that was at least 10 minutes ago (it then counts as told).
_weekly_observe() {
  local account=$1 share=${2:-} cached stored file now
  cached=$(_cache_weekly "$account")
  [[ -n $cached ]] || return 1
  file=$(_weekly_file "$account")
  stored=$(_stored_weekly "$file")
  if [[ -z $stored ]] || jq -e --argjson c "$cached" '$c.at > .at' >/dev/null <<<"$stored"; then
    printf '%s\n' "$cached" >"$file.new" && mv -f -- "$file.new" "$file"
  elif ! jq -e --argjson c "$cached" '$c.at == .at and .from == ""' >/dev/null <<<"$stored"; then
    return 1   # the newest is another machine's: it is never told again from here
  fi
  [[ $share == share ]] || return 1
  now=$(date +%s)
  if jq -e --argjson c "$cached" --argjson now "$now" '.percent == $c.percent or $now - .at < 600' \
      "$file-shared" >/dev/null 2>&1; then
    return 1
  fi
  jq -cn --argjson c "$cached" --argjson now "$now" '{percent:$c.percent, at:$now}' >"$file-shared"
  printf '%s\n' "$cached"
}
account_weekly_observe() { state_locked accounts _weekly_observe "$@"; }

_weekly_learn() {
  local file=$1 record=$2 stored
  stored=$(_stored_weekly "$file")
  [[ -z $stored ]] || jq -e --argjson r "$record" '$r.at > .at' >/dev/null <<<"$stored" || return 1
  printf '%s\n' "$record" >"$file.new" && mv -f -- "$file.new" "$file"
}

# account_learn_weekly ACCOUNT PERCENT RESETS_AT AT FROM: records the weekly usage another machine read at AT, when it
# is newer than the one known here. Fails when it changes nothing.
account_learn_weekly() {
  local account=$1 percent=$2 resets=${3:-} at=$4 from=${5:-}
  [[ $percent =~ ^[0-9]+([.][0-9]+)?$ && $at =~ ^[0-9]+$ && -n $from ]] || return 1
  state_locked accounts _weekly_learn "$(_weekly_file "$account")" "$(jq -cn --argjson percent "$percent" \
    --arg resets "$resets" --argjson at "$at" --arg from "$from" \
    '{percent:$percent, resets_at:(if $resets == "" then null else $resets end), at:$at, from:$from}')"
}

_date_in() { # ZONE DATE-ARGUMENTS...: date in that zone, or in the system zone when ZONE is empty
  local zone=$1
  shift
  if [[ -n $zone ]]; then TZ=$zone date "$@"; else date "$@"; fi
}

# The reset time of a limit message -> epoch. Fails when it cannot read it.
#   "You've hit your weekly limit · resets Oct 16, 4pm (America/Sao_Paulo)": that time in that zone.
#   "5-hour limit reached ∙ resets 3pm": that time in the system zone (Claude Code wrote it in the zone of this
#   machine); never when a zone follows that is not a zone name.
reset_epoch_from_text() {
  local text=$1 pattern when zone='' epoch now year rest
  # The time stops at a parenthesis, a quote, a backslash (inside a JSON string) or the end of the line.
  pattern='resets[[:space:]]+([^()"\'$'\n'']*[^()"\[:space:]])[[:space:]]*\(([A-Za-z0-9_/+-]+)\)'
  if [[ $text =~ $pattern ]]; then
    when=${BASH_REMATCH[1]}
    zone=${BASH_REMATCH[2]}
  else
    pattern='resets[[:space:]]+([^()"\'$'\n'']*[^()"\.[:space:]])'
    [[ $text =~ $pattern ]] || return 1
    when=${BASH_REMATCH[1]}
    rest=${text#*"${BASH_REMATCH[0]}"}
    [[ ! $rest =~ ^[[:space:]]*\( ]] || return 1
  fi
  when=${when//,/ }
  when=${when// at / }
  now=$(date +%s)
  epoch=$(_date_in "$zone" -d "$when" +%s 2>/dev/null) || return 1
  if (( epoch <= now )); then
    if [[ $when =~ ^[A-Za-z]+[[:space:]]+[0-9]+ ]]; then
      # A date already past this year means next year; a bare time already past means tomorrow.
      year=$(_date_in "$zone" +%Y)
      epoch=$(_date_in "$zone" -d "$when $((year + 1))" +%s 2>/dev/null) || return 1
    else
      epoch=$(_date_in "$zone" -d "$when tomorrow" +%s 2>/dev/null) || return 1
    fi
  fi
  printf '%s\n' "$epoch"
}

# When the account is back: the reset in the error text, else the epoch the caller read elsewhere (quotaLimits.resetsAt
# of a history entry), else one hour from now. The weekly reset of the usage file is never a guess for a limit without
# a time: it overstates a 5-hour limit, and the fleet would learn the account is out until the end of the week.
account_reset_epoch() {
  local text=${2:-} hint=${3:-} epoch
  if epoch=$(reset_epoch_from_text "$text"); then printf '%s\n' "$epoch"; return 0; fi
  if [[ $hint =~ ^[0-9]+$ ]] && (( hint > $(date +%s) )); then printf '%s\n' "$hint"; return 0; fi
  printf '%s\n' "$(( $(date +%s) + 3600 ))"
}

_write_out_until() { # FILE EPOCH AT [FROM]
  printf '%s\n' "$2" >"$1"
  printf '%s %s\n' "$3" "${4:-}" >"${1%.out-until}.out-news"
}

# The account's identity, "<accountUuid>/<organizationUuid>" from its .claude.json, the same on every machine where
# the account is logged in; empty when unknown. ~/.claude keeps that file in the home folder.
account_identity() {
  local account=${1%/} file identity
  local -a files=("$account/.claude.json")
  [[ $account != "$HOME/.claude" ]] || files=("$HOME/.claude.json" "$account/.claude.json")
  for file in "${files[@]}"; do
    [[ -f $file ]] || continue
    identity=$(jq -r '.oauthAccount // {} | if .accountUuid then "\(.accountUuid)/\(.organizationUuid // "")" else empty end' \
      "$file" 2>/dev/null) || identity=''
    [[ -z $identity ]] || { printf '%s\n' "$identity"; return 0; }
  done
}

# Whether Claude Code was ever opened interactively in the account on this machine (its first-run screens are done).
# A clone started in an account that never was would stop on those screens, with nobody looking.
account_onboarded() {
  local account=${1%/} file
  local -a files=("$account/.claude.json")
  [[ $account != "$HOME/.claude" ]] || files=("$HOME/.claude.json" "$account/.claude.json")
  for file in "${files[@]}"; do
    [[ -f $file ]] || continue
    jq -e '.hasCompletedOnboarding == true' "$file" >/dev/null 2>&1 && return 0
  done
  return 1
}

# The local account that is the account IDENTITY (KEY) of another machine: the same identity, or the same key when
# either identity is unknown. Fails when there is none.
account_matching() {
  local identity=$1 key=$2 account own
  while IFS= read -r account; do
    [[ -n $account ]] || continue
    own=$(account_identity "$account")
    if [[ -n $identity && -n $own ]]; then
      [[ $own != "$identity" ]] || { printf '%s\n' "$account"; return 0; }
    elif [[ $(account_key "$account") == "$key" ]]; then
      printf '%s\n' "$account"; return 0
    fi
  done < <(accounts_list)
  return 1
}

_forget_out_until() { rm -f -- "$1" "${1%.out-until}.out-news"; }

# The time of the newest call that worked in the account known here (a clear, from this machine or another), "" if none.
_back_at() {
  local value=''
  IFS= read -r value 2>/dev/null <"${1%.out-until}.back-at" || true
  [[ $value =~ ^[0-9]+$ ]] && printf '%s\n' "$value"
  return 0
}

# _learn_out_until FILE EPOCH AT FROM: a newer news of the machine the known one came from replaces it, even when it
# moves the epoch earlier, so a machine that told a guess can correct it. Between different machines the later epoch
# wins: a guess somewhere never frees an account another machine read is out longer. News without a time (from an
# older udarnik) only ever moves it later. An out-until that is over is gone.
# A clear leaves its time in <key>.back-at (see _clear_out_until), and a news of "out" that is not newer than that call
# is the one the call has just proved wrong, arriving late (a machine that missed the clear, a slow delivery): it is
# rejected. A news without a time cannot be dated, so it is rejected only while the clear is newer than the out-until
# it brings (an out-until that ends before the call that worked is already over).
_learn_out_until() {
  local file=$1 epoch=$2 at=$3 from=$4 current news_at='' news_from='' now back_at
  now=$(date +%s)
  back_at=$(_back_at "$file")
  if [[ -n $back_at ]]; then
    if [[ -n $at ]]; then ((at > back_at)) || return 1; else ((epoch > back_at)) || return 1; fi
  fi
  current=$(cat -- "$file" 2>/dev/null || true)
  [[ $current =~ ^[0-9]+$ ]] || current=0
  IFS=' ' read -r news_at news_from 2>/dev/null <"${file%.out-until}.out-news" || true
  [[ $news_at =~ ^[0-9]+$ ]] || news_at=''
  if ((current <= now)); then
    _forget_out_until "$file"
    current=0 news_at='' news_from=''
  fi
  if [[ -n $at && -n $news_at && -n $from && $from == "$news_from" ]]; then
    ((at > news_at)) || return 1
  else
    ((epoch > current)) || return 1
    [[ -n $at ]] || at=$now
  fi
  _write_out_until "$file" "$epoch" "$at" "$from"
  ((epoch != current))
}

# account_learn_out ACCOUNT EPOCH [AT [FROM]]: records an out-until another machine (FROM) learned at AT. Fails when
# the epoch here did not change.
account_learn_out() {
  local at=${3:-}
  [[ $2 =~ ^[0-9]+$ ]] && (($2 > $(date +%s))) || return 1
  [[ $at =~ ^[0-9]+$ ]] || at=''
  state_locked accounts _learn_out_until "$(_out_until_file "$1")" "$2" "$at" "${4:-}"
}

# Whether the account is marked out of quota right now. Builtins only, no process and no lock: it is the question
# asked after every call that worked, so the common answer (no) has to be free.
account_marked_out() {
  local name=${1%/} value='' now
  name=${name##*/}
  IFS= read -r value 2>/dev/null <"$(udarnik_state_dir)/accounts/${name#.}.out-until" || true
  [[ $value =~ ^[0-9]+$ ]] || return 1
  printf -v now '%(%s)T' -1
  # The tests' clock (see UDARNIK_CLOCK_OFFSET in bin/udarnik).
  if [[ ${UDARNIK_CLOCK_OFFSET:-} =~ ^-?[0-9]+$ ]]; then now=$((now + UDARNIK_CLOCK_OFFSET)); fi
  ((value > now))
}

# _clear_out_until FILE AT: a call worked in the account (here or on another machine) and ended at AT. Under the lock:
#   - AT is kept in <key>.back-at (the newest wins), even when there is no mark to remove, so the "out" news older than
#     the call that comes later (see _learn_out_until) cannot mark the account again;
#   - the out-until goes when the news of it is older than AT; a mark made after that call stays, and so does one whose
#     time is unknown (an older udarnik), which is not proved older.
# A call cannot end after now, so an AT in the future (a runner that passes milliseconds, a clock ahead) is taken as now:
# it would otherwise free a mark made after the call and reject every news of "out" from then on.
# Succeeds when it removed an out-until that was still to come.
_clear_out_until() {
  local file=$1 at=$2 value news_at='' news_from='' back_at now
  now=$(date +%s)
  ((${#at} < 12 && at <= now)) || at=$now
  back_at=$(_back_at "$file")
  if [[ -z $back_at ]] || ((at > back_at)); then printf '%s\n' "$at" >"${file%.out-until}.back-at"; fi
  value=$(cat -- "$file" 2>/dev/null || true)
  [[ $value =~ ^[0-9]+$ ]] && ((value > now)) || return 1
  IFS=' ' read -r news_at news_from 2>/dev/null <"${file%.out-until}.out-news" || true
  [[ $news_at =~ ^[0-9]+$ ]] && ((news_at < at)) || return 1
  _forget_out_until "$file"
}

# account_note_back ACCOUNT AT: the cheap half of a clear, for an account that is not marked out. Keeps AT in
# <key>.back-at when it is newer than the one there, with builtins only: no process, no lock, no ssh. Without the lock
# a concurrent clear may lose the race and leave an older time, which only means one stale news is accepted. AT must not
# be in the future (the caller checks).
account_note_back() {
  local name=${1%/} file back=''
  [[ $2 =~ ^[0-9]+$ ]] || return 1
  name=${name##*/}
  file="$(udarnik_state_dir)/accounts/${name#.}.back-at"
  IFS= read -r back 2>/dev/null <"$file" || true
  [[ $back =~ ^[0-9]+$ ]] && (($2 <= back)) && return 0
  printf '%s\n' "$2" 2>/dev/null >"$file" || true
}

# account_clear ACCOUNT AT: a call that ended at AT worked in the account, so it is back, whatever the out-until said,
# unless the mark is newer than the call. Succeeds when it removed the mark; fails when there was none (changing
# nothing, without the lock) or when it stayed.
account_clear() {
  [[ $2 =~ ^[0-9]+$ ]] || return 1
  account_marked_out "$1" || return 1
  state_locked accounts _clear_out_until "$(_out_until_file "$1")" "$2"
}

# account_learn_clear ACCOUNT AT: a call worked in the account on another machine, ending at AT. Succeeds when it
# removed the mark. The time is kept even then (see _clear_out_until).
account_learn_clear() {
  [[ $2 =~ ^[0-9]+$ ]] || return 1
  state_locked accounts _clear_out_until "$(_out_until_file "$1")" "$2"
}

_forget_expired() {
  local account file value now
  now=$(date +%s)
  while IFS= read -r account; do
    [[ -n $account ]] || continue
    file=$(_out_until_file "$account")
    [[ -f $file ]] || continue
    value=$(cat -- "$file" 2>/dev/null || true)
    [[ $value =~ ^[0-9]+$ ]] && ((value > now)) || _forget_out_until "$file"
  done < <(accounts_list)
}
# Removes the out-until of the accounts that are back.
accounts_forget_expired() { state_locked accounts _forget_expired; }

# _mark_out_until FILE EPOCH GUESS: a guess (no time in the text nor in the history) never moves an out-until that is
# still to come earlier; it fails then, and prints the epoch kept.
_mark_out_until() {
  local file=$1 epoch=$2 guess=$3 current
  current=$(cat -- "$file" 2>/dev/null || true)
  if $guess && [[ $current =~ ^[0-9]+$ ]] && ((current > epoch)); then
    printf '%s\n' "$current"
    return 1
  fi
  _write_out_until "$file" "$epoch" "$(date +%s)"
  printf '%s\n' "$epoch"
}

# account_mark_out <account> <error text> [reset epoch hint]: prints the epoch the account is back. Fails when that is
# not news to tell the fleet: the limit gave no time, and the out-until already known is later than the guess.
account_mark_out() {
  local account=$1 text=${2:-} hint=${3:-} epoch guess=true
  if reset_epoch_from_text "$text" >/dev/null || { [[ $hint =~ ^[0-9]+$ ]] && ((hint > $(date +%s))); }; then
    guess=false
  fi
  epoch=$(account_reset_epoch "$account" "$text" "$hint")
  if ! epoch=$(state_locked accounts _mark_out_until "$(_out_until_file "$account")" "$epoch" "$guess"); then
    udarnik_log "account $(account_key "$account") hit its limit again without a reset time; it stays out of quota until $(date -d "@$epoch" '+%d/%m %H:%M'), as known"
    printf '%s\n' "$epoch"
    return 1
  fi
  udarnik_log "account $(account_key "$account") is out of quota until $(date -d "@$epoch" '+%d/%m %H:%M')"
  printf '%s\n' "$epoch"
}

# The preference order of the accounts for a kind of caller (interactive, worker), as account keys:
# UDARNIK_ORDER_<KIND> (keys separated by commas, colons or spaces), else the state file order.<kind> (one key per
# line, # starts a comment). Nothing without a kind or without either.
account_order() {
  local kind=${1:-} variable value file entry
  [[ $kind =~ ^[a-z]+$ ]] || return 0
  variable="UDARNIK_ORDER_${kind^^}"
  value=${!variable:-}
  file="$(udarnik_state_dir)/order.$kind"
  if [[ -z $value && -f $file ]]; then value=$(sed 's/#.*//' "$file"); fi
  while IFS= read -r entry; do
    [[ -z $entry ]] || account_key "$entry"
  done < <(tr ',: \t' '\n\n\n\n' <<<"$value")
}

# The available account to go to: the first of the order of PICK_KIND (see account_order) that is available, else the
# one with the lowest weekly usage (unknown usage goes last). Skips the excluded ones (paths or keys). With
# PICK_ONBOARDED=1 (an interactive clone), only accounts where Claude Code was opened interactively. Fails when none
# is available.
account_pick() {
  local account best='' best_percent='' percent excluded skip key
  local -a candidates=()
  while IFS= read -r account; do
    [[ -n $account ]] || continue
    skip=false
    for excluded in "$@"; do
      [[ $(account_key "$account") == "$(account_key "$excluded")" ]] && skip=true
    done
    $skip && continue
    account_available "$account" || continue
    [[ ${PICK_ONBOARDED:-0} != 1 ]] || account_onboarded "$account" || continue
    candidates+=("$account")
  done < <(accounts_list)
  ((${#candidates[@]})) || return 1
  while IFS= read -r key; do
    for account in "${candidates[@]}"; do
      [[ $(account_key "$account") != "$key" ]] || { printf '%s\n' "$account"; return 0; }
    done
  done < <(account_order "${PICK_KIND:-}")
  for account in "${candidates[@]}"; do
    percent=$(account_weekly_percent "$account")
    [[ $percent =~ ^[0-9]+([.][0-9]+)?$ ]] || percent=100000
    if [[ -z $best ]] || awk -v a="$percent" -v b="$best_percent" 'BEGIN { exit !(a < b) }'; then
      best=$account
      best_percent=$percent
    fi
  done
  [[ -n $best ]] || return 1
  printf '%s\n' "$best"
}

is_limit_text() { printf '%s' "$*" | grep -Eqi 'hit your .*limit|usage limit reached'; }

# Local "dd/mm HH:MM" for an epoch, in the system zone (TZ is honored when set).
local_time() { date -d "@$1" '+%d/%m %H:%M'; }

_link_warned() {
  local file="$(udarnik_state_dir)/links-warned"
  grep -Fxq -- "$1" "$file" 2>/dev/null && return 0
  printf '%s\n' "$1" >>"$file"
  return 1
}

# Links source at destination. A real folder or file is never replaced (logged once); a symlink is replaced
# only when it is dangling or already points into the shared folder.
_link_shared() {
  local source=$1 destination=$2 current shared=${3%/}
  if [[ -L $destination ]]; then
    current=$(readlink -- "$destination")
    [[ $current == "$source" ]] && return 0
    if [[ -e $destination && $current != "$shared"/* ]]; then
      state_locked links _link_warned "$destination" || udarnik_log "link ignored: $destination points elsewhere ($current)"
      return 0
    fi
    ln -sfn -- "$source" "$destination"
    udarnik_log "link updated: $destination -> $source"
  elif [[ -e $destination ]]; then
    state_locked links _link_warned "$destination" || udarnik_log "link ignored: $destination is a real folder; nothing was replaced"
  else
    mkdir -p -- "$(dirname -- "$destination")"
    ln -s -- "$source" "$destination"
    udarnik_log "link created: $destination -> $source"
  fi
}

# Memories and skills are shared between accounts through symlinks into the shared folder. Idempotent. Does nothing
# when the folder does not exist.
ensure_shared_links() {
  local shared account source slug
  shared=$(_shared_dir)
  shared=${shared%/}
  [[ -d $shared ]] || return 0
  while IFS= read -r account; do
    [[ -n $account ]] || continue
    # An account whose projects (or skills) folder is the shared one already shares all of it.
    if [[ ! $account/projects -ef $shared/projects ]]; then
      for source in "$shared"/projects/*/memory; do
        [[ -d $source ]] || continue
        slug=$(basename -- "$(dirname -- "$source")")
        _link_shared "$source" "$account/projects/$slug/memory" "$shared"
      done
    fi
    [[ ! $account/skills -ef $shared/skills ]] || continue
    for source in "$shared"/skills/*; do
      [[ -d $source ]] || continue
      _link_shared "$source" "$account/skills/$(basename -- "$source")" "$shared"
    done
  done < <(accounts_list)
  return 0
}
