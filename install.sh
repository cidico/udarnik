#!/usr/bin/env bash
# Installs, updates or removes udarnik.
#
#   ./install.sh              install or update (tree, command link, /takeover skill)
#   ./install.sh --force      also replace a skills/takeover or command link that udarnik does not own
#   ./install.sh --uninstall  remove what this script installed (the state directory is kept)
#
# Respects HOME, UDARNIK_PREFIX, UDARNIK_ACCOUNTS, UDARNIK_SHARED_DIR and UDARNIK_UNIT. Never restarts the service.
set -Eeuo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PREFIX=${UDARNIK_PREFIX:-$HOME/.local/share/udarnik}
PREFIX=${PREFIX%/}
UNIT=${UDARNIK_UNIT:-udarnik}
SHARED=${UDARNIK_SHARED_DIR:-$HOME/.claude-shared}
SHARED=${SHARED%/}
LINK="$HOME/.local/bin/udarnik"
MARKER=.udarnik

# shellcheck source=lib/accounts.sh
source "$SOURCE_DIR/lib/accounts.sh"

mode=install
force=false
for argument in "$@"; do
  case "$argument" in
    --uninstall) mode=uninstall ;;
    --force) force=true ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'install.sh: unknown option: %s\n' "$argument" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
fail() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

service_active() { systemctl --user is-active --quiet "$UNIT.service" 2>/dev/null; }

# A skill dir (or a link to one) that this script installed carries the marker file.
owned() { [[ -e $1/$MARKER ]]; }

remove_path() { if [[ -L $1 ]]; then rm -f -- "$1"; else rm -rf -- "$1"; fi; }

check_dependencies() {
  local missing=() tool
  ((BASH_VERSINFO[0] >= 4)) || missing+=('bash >= 4')
  for tool in jq tmux python3 flock setsid systemd-run systemctl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
  done
  if ((${#missing[@]})); then
    fail "missing requirement(s): ${missing[*]}"
  fi
  systemctl --user show-environment >/dev/null 2>&1 \
    || fail "'systemctl --user' is not reachable: udarnik needs the systemd user manager (is a user session running?)"
  command -v claude >/dev/null 2>&1 || warn "'claude' is not in PATH; the service resolves it through its own PATH when it starts a clone"
}

# Fresh copy of the tree through a staging dir and a rename, so a running command never sees a half-copied tree.
install_tree() {
  local staging="$PREFIX.staging"
  case "$PREFIX" in
    ''|/|"$HOME") fail "refusing to install into '$PREFIX'" ;;
  esac
  [[ $SOURCE_DIR != "$PREFIX" ]] || fail "the source tree is the install prefix; run install.sh from a checkout"
  if [[ -e $PREFIX || -L $PREFIX ]] && [[ ! -e $PREFIX/$MARKER ]] && ! $force; then
    if [[ -d $PREFIX && -z $(ls -A -- "$PREFIX") ]]; then :; else
      fail "$PREFIX exists and is not an udarnik tree; choose another UDARNIK_PREFIX or use --force"
    fi
  fi
  rm -rf -- "$staging"
  mkdir -p -- "$staging"
  cp -a -- "$SOURCE_DIR/bin" "$SOURCE_DIR/lib" "$SOURCE_DIR/skills" "$staging/"
  printf 'installed by udarnik install.sh\n' >"$staging/$MARKER"
  remove_path "$PREFIX"
  mkdir -p -- "$(dirname -- "$PREFIX")"
  mv -- "$staging" "$PREFIX"
  say "installed the tree in $PREFIX"
}

install_link() {
  mkdir -p -- "$(dirname -- "$LINK")"
  if [[ -e $LINK || -L $LINK ]]; then
    if [[ -L $LINK && $(readlink -- "$LINK") == "$PREFIX/bin/udarnik" ]] || $force; then
      :
    else
      say "skipped: $LINK exists and is not an udarnik link (use --force to replace it)"
      return 0
    fi
  fi
  ln -sfn -- "$PREFIX/bin/udarnik" "$LINK"
  say "linked $LINK -> $PREFIX/bin/udarnik"
  case ":$PATH:" in
    *":$(dirname -- "$LINK"):"*) ;;
    *) warn "$(dirname -- "$LINK") is not in PATH; add it to run 'udarnik'" ;;
  esac
}

# Copies the skill into a fresh dir with the marker (staging + rename).
copy_skill_to() {
  local destination=$1 staging
  staging="$destination.staging"
  rm -rf -- "$staging"
  mkdir -p -- "$staging"
  cp -a -- "$PREFIX/skills/takeover/." "$staging/"
  printf 'installed by udarnik install.sh\n' >"$staging/$MARKER"
  mkdir -p -- "$(dirname -- "$destination")"
  remove_path "$destination"
  mv -- "$staging" "$destination"
}

# True when the path may be written: absent, ours, or --force. Prints what was skipped otherwise.
may_replace() {
  local path=$1
  if [[ ! -e $path && ! -L $path ]]; then return 0; fi
  if owned "$path" || $force; then return 0; fi
  say "skipped: $path exists and was not installed by udarnik (use --force to replace it)"
  return 1
}

install_skill() {
  local account shared_skill="$SHARED/skills/takeover" destination
  if [[ -d $SHARED ]]; then
    if ! may_replace "$shared_skill"; then return 0; fi
    copy_skill_to "$shared_skill"
    say "installed the skill in $shared_skill"
    while IFS= read -r account; do
      [[ -n $account && -d $account ]] || continue
      destination="$account/skills/takeover"
      may_replace "$destination" || continue
      mkdir -p -- "$account/skills"
      remove_path "$destination"
      ln -s -- "$shared_skill" "$destination"
      say "linked $destination -> $shared_skill"
    done < <(accounts_list)
  else
    while IFS= read -r account; do
      [[ -n $account && -d $account ]] || continue
      destination="$account/skills/takeover"
      may_replace "$destination" || continue
      copy_skill_to "$destination"
      say "installed the skill in $destination"
    done < <(accounts_list)
  fi
}

do_install() {
  check_dependencies
  install_tree
  install_link
  install_skill
  if service_active; then
    say "The udarnik service is running and keeps the old version until: udarnik stop --all, then udarnik start"
  fi
  say "Done. Try: udarnik status"
}

do_uninstall() {
  local account destination state
  state=$(udarnik_state_dir)
  if service_active; then
    if [[ -x $PREFIX/bin/udarnik ]]; then "$PREFIX/bin/udarnik" stop || true; else "$SOURCE_DIR/bin/udarnik" stop || true; fi
  fi
  if [[ -L $LINK && $(readlink -- "$LINK") == "$PREFIX/bin/udarnik" ]]; then
    rm -f -- "$LINK"
    say "removed $LINK"
  elif [[ -e $LINK || -L $LINK ]]; then
    say "kept: $LINK is not an udarnik link"
  fi
  while IFS= read -r account; do
    [[ -n $account ]] || continue
    destination="$account/skills/takeover"
    if [[ ( -e $destination || -L $destination ) ]] && owned "$destination"; then
      remove_path "$destination"
      say "removed $destination"
    fi
  done < <(accounts_list)
  if [[ -d $SHARED/skills/takeover ]] && owned "$SHARED/skills/takeover"; then
    rm -rf -- "$SHARED/skills/takeover"
    say "removed $SHARED/skills/takeover"
  fi
  if [[ -e $PREFIX/$MARKER ]]; then
    rm -rf -- "$PREFIX"
    say "removed $PREFIX"
  fi
  say "The state directory was kept: $state"
}

case "$mode" in
  install) do_install ;;
  uninstall) do_uninstall ;;
esac
