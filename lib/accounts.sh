#!/usr/bin/env bash
# Claude account logic shared by bin/udarnik and by any runner that wants the same failover. Sourced, never executed.
#
# State lives in ${UDARNIK_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/udarnik}:
#   enabled                  switch file: failover and takeover work only while it exists
#   accounts/<key>.out-until epoch until which an account is out of quota
#   sessions.json            interactive sessions taken over (written by bin/udarnik)
#   context                  owner note appended to the takeover message
#   only                     session id prefixes the takeover is limited to (one per line)
#   root                     directory the takeover is limited to (sessions at or below it)
#   udarnik.log              the single log
# Every write happens under flock. <key> is the account directory name without its leading dot.
# Nothing here ever touches the network: the weekly usage is only read from a file a statusline keeps.

udarnik_state_dir() { printf '%s\n' "${UDARNIK_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/udarnik}"; }

udarnik_enabled() { [[ -f "$(udarnik_state_dir)/enabled" ]]; }

# Runs a command (function or program) while holding the named state lock.
state_locked() {
  local name=$1 dir
  shift
  dir=$(udarnik_state_dir)
  (umask 077; mkdir -p -- "$dir/accounts")
  ( flock -x 9; "$@" ) 9>"$dir/.$name.lock"
}

_append_log_line() { printf '%s\n' "$1" >>"$(udarnik_state_dir)/udarnik.log"; }

# One line in udarnik.log; also on stdout when UDARNIK_LOG_STDOUT=1 (the service journal).
udarnik_log() {
  local line
  line="$(date -Is) $*"
  state_locked log _append_log_line "$line"
  [[ ${UDARNIK_LOG_STDOUT:-0} != 1 ]] || printf '%s\n' "$line"
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

# Weekly percentage from the usage file; empty when unknown.
account_weekly_percent() {
  local file
  file=$(_usage_cache_file "$1")
  [[ -f $file ]] || return 0
  jq -r '[.limits[]? | select(.kind == "weekly_all") | .percent][0] // empty' "$file" 2>/dev/null || true
}

_cache_weekly_reset() {
  local file stamp
  file=$(_usage_cache_file "$1")
  [[ -f $file ]] || return 1
  stamp=$(jq -r '[.limits[]? | select(.kind == "weekly_all") | .resets_at][0] // empty' "$file" 2>/dev/null) || return 1
  [[ -n $stamp ]] || return 1
  date -d "$stamp" +%s 2>/dev/null
}

# "You've hit your weekly limit · resets Oct 16, 4pm (America/Sao_Paulo)" -> epoch. Fails when it cannot read it.
reset_epoch_from_text() {
  local text=$1 pattern when zone epoch now year
  pattern='resets[[:space:]]+(.+)[[:space:]]+\(([A-Za-z0-9_/+-]+)\)'
  [[ $text =~ $pattern ]] || return 1
  when=${BASH_REMATCH[1]}
  zone=${BASH_REMATCH[2]}
  when=${when//,/ }
  when=${when// at / }
  now=$(date +%s)
  epoch=$(TZ=$zone date -d "$when" +%s 2>/dev/null) || return 1
  if (( epoch <= now )); then
    if [[ $when =~ ^[A-Za-z]+[[:space:]]+[0-9]+ ]]; then
      # A date already past this year means next year; a bare time already past means tomorrow.
      year=$(TZ=$zone date +%Y)
      epoch=$(TZ=$zone date -d "$when $((year + 1))" +%s 2>/dev/null) || return 1
    else
      epoch=$(TZ=$zone date -d "$when tomorrow" +%s 2>/dev/null) || return 1
    fi
  fi
  printf '%s\n' "$epoch"
}

# When the account is back: the reset in the error text, else the epoch the caller read elsewhere (a history
# entry), else the weekly reset in the usage file, else one hour from now.
account_reset_epoch() {
  local account=$1 text=${2:-} hint=${3:-} epoch
  if epoch=$(reset_epoch_from_text "$text"); then printf '%s\n' "$epoch"; return 0; fi
  if [[ $hint =~ ^[0-9]+$ ]] && (( hint > $(date +%s) )); then printf '%s\n' "$hint"; return 0; fi
  if epoch=$(_cache_weekly_reset "$account") && (( epoch > $(date +%s) )); then printf '%s\n' "$epoch"; return 0; fi
  printf '%s\n' "$(( $(date +%s) + 3600 ))"
}

_write_out_until() { printf '%s\n' "$2" >"$1"; }

# account_mark_out <account> <error text> [reset epoch hint]: prints the epoch the account is back.
account_mark_out() {
  local account=$1 text=${2:-} hint=${3:-} epoch
  epoch=$(account_reset_epoch "$account" "$text" "$hint")
  state_locked accounts _write_out_until "$(_out_until_file "$account")" "$epoch"
  udarnik_log "account $(account_key "$account") is out of quota until $(date -d "@$epoch" '+%d/%m %H:%M')"
  printf '%s\n' "$epoch"
}

# The available account with the lowest weekly usage, skipping the excluded ones (paths or keys). Unknown usage
# goes last. Fails when none is available.
account_pick() {
  local account best='' best_percent='' percent excluded skip
  while IFS= read -r account; do
    [[ -n $account ]] || continue
    skip=false
    for excluded in "$@"; do
      [[ $(account_key "$account") == "$(account_key "$excluded")" ]] && skip=true
    done
    $skip && continue
    account_available "$account" || continue
    percent=$(account_weekly_percent "$account")
    [[ $percent =~ ^[0-9]+([.][0-9]+)?$ ]] || percent=100000
    if [[ -z $best ]] || awk -v a="$percent" -v b="$best_percent" 'BEGIN { exit !(a < b) }'; then
      best=$account
      best_percent=$percent
    fi
  done < <(accounts_list)
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
    for source in "$shared"/projects/*/memory; do
      [[ -d $source ]] || continue
      slug=$(basename -- "$(dirname -- "$source")")
      _link_shared "$source" "$account/projects/$slug/memory" "$shared"
    done
    for source in "$shared"/skills/*; do
      [[ -d $source ]] || continue
      _link_shared "$source" "$account/skills/$(basename -- "$source")" "$shared"
    done
  done < <(accounts_list)
  return 0
}
