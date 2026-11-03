#!/usr/bin/env bash
# Proves that tests/udarnik.sh never reads or writes the real state of the machine and never reaches a real process.
# It builds a "real" environment as poisoned as the one of a clone of the real service (its UDARNIK_STATE with an
# account marked out and a log of ISO lines, the switch that sent log lines to stdout, its tmux socket and a live tmux
# server under that name, a fleet file, an ssh, a clock offset, a BASH_ENV, CLAUDE_CONFIG_DIR...), runs the battery
# from a copy of this checkout inside it, and checks that:
#   1. the battery passes;
#   2. the poisoned home, state and tmux server are exactly as they were;
#   3. no canary ran (udarnik, claude, ssh, systemctl, systemd-run found through the poisoned PATH, the BASH_ENV);
#   4. every file the battery and its processes opened, executed, created, removed or renamed is under /tmp, /proc,
#      /dev or the system folders (/usr, /etc, /lib, /lib64, /bin, /sbin, /sys, the user database /run/systemd/userdb).
#   5. no /proc/<pid> of a process that is not one of the battery's (every pid of the trace, and every pid one of
#      them forked) was opened: a real worker's command line and environment (a token) are never read;
#   6. nothing under the poisoned home, state, tmux folder or canaries was opened, run, created or removed (they are
#      under /tmp, which 4 allows), but the BASH_ENV the shell that starts the battery reads before its first line.
#      With strace (strace -f, the calls of the file class that open, run, create, remove or rename, and %process);
#      without it, with a LD_PRELOAD tracer built here (cc), which sees the calls through the C library, in every
#      process, the environment of `env -i` included. Neither available: 4 to 6 are skipped, and said so.
# Run: bash tests/isolation.sh   (UDARNIK_TEST_NOW is passed to the battery; ISOLATION_KEEP=1 keeps the work folder)

set -uo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d /tmp/udarnik-isolation.XXXXXX)
trap '[[ -n ${ISOLATION_KEEP:-} ]] && printf "kept %s\n" "$work" >&2 || rm -rf -- "$work"; TMUX_TMPDIR="$work/real-tmux" tmux -L udarnik kill-server 2>/dev/null || true' EXIT
failed=0
check() { if "${@:2}"; then printf 'ok - %s\n' "$1"; else printf 'not ok - %s\n' "$1" >&2; failed=1; fi; }

# A copy of the checkout, so that reading the code is a read under /tmp too.
mkdir -p "$work/repo"
cp -r "$repo_root/bin" "$repo_root/lib" "$repo_root/tests" "$repo_root/skills" "$repo_root/install.sh" "$repo_root/README.md" "$work/repo/"

# ------------------------------------------------------------------ the poisoned "real" machine
real="$work/real-home"
canary="$work/canary"
mkdir -p "$real/.local/state/udarnik/accounts" "$real/.local/bin" "$real/.config/agentic" "$real/.cache" \
  "$real/.claude/sessions" "$real/.claude-work/sessions" "$canary/bin" "$work/real-tmux"
future=$(( $(date +%s) + 2 * 86400 ))
printf '%s\n' "$future" >"$real/.local/state/udarnik/accounts/claude.out-until"
printf '%s here\n' "$(date +%s)" >"$real/.local/state/udarnik/accounts/claude.out-news"
printf '%s\n' "$future" >"$real/.local/state/udarnik/accounts/claude-c.out-until"
for i in 1 2 3; do printf '%s account claude is out of quota until 04/11 02:00\n' "$(date -Is)"; done >"$real/.local/state/udarnik/udarnik.log"
printf '%s round: 7 sessions watched, 2 at the limit, 2 live clones\n' "2026-11-02T02:18:58-03:00" >>"$real/.local/state/udarnik/udarnik.log"
: >"$real/.local/state/udarnik/enabled"
printf 'claude-work\n' >"$real/.local/state/udarnik/order.worker"
printf '{"machines":{"real":{"ssh":"real-host","id":"real-id"}}}\n' >"$real/.config/agentic/fleet.json"
printf '{"limits":[{"kind":"weekly_all","percent":99,"resets_at":null}]}\n' >"$real/.cache/claude-statusline-usage-claude.json"
for account in .claude .claude-work; do printf 'poison\n' >"$real/$account/.credentials.json"; done
for name in udarnik claude ssh systemctl systemd-run; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >>%q\nexit 1\n' "$name" "$canary/calls" >"$canary/bin/$name"
  cp "$canary/bin/$name" "$real/.local/bin/$name"
done
chmod +x "$canary/bin/"* "$real/.local/bin/"*
printf 'printf "BASH_ENV %%s\\n" "$0" >>%q\n' "$canary/calls" >"$canary/bash_env"
# A live tmux server with the name of the real one, in the poisoned tmux folder.
TMUX_TMPDIR="$work/real-tmux" tmux -L udarnik new-session -d -s udarnik -n real-clone 'sleep 3600'
tmux_windows() { TMUX_TMPDIR="$work/real-tmux" tmux -L udarnik list-windows -a -F '#{window_name}' 2>&1; }
windows_before=$(tmux_windows)
fingerprint() { (cd "$real" && find . -printf '%p %s %T@ %m\n' | sort && find . -type f -exec sha256sum {} + | sort); }
before=$(fingerprint)

poison=(
  HOME="$real" PATH="$canary/bin:$real/.local/bin:/usr/local/bin:/usr/bin:/bin"
  XDG_STATE_HOME="$real/.local/state" XDG_CACHE_HOME="$real/.cache" XDG_CONFIG_HOME="$real/.config"
  XDG_DATA_HOME="$real/.local/share" TMUX_TMPDIR="$work/real-tmux" TMUX="$work/real-tmux/tmux-$(id -u)/udarnik,1,0"
  TMUX_PANE=%0 BASH_ENV="$canary/bash_env" CLAUDE_CONFIG_DIR="$real/.claude-work"
  UDARNIK_STATE="$real/.local/state/udarnik" UDARNIK_LOG_STDOUT=1 UDARNIK_LOG_JOURNAL=1
  UDARNIK_TMUX_SOCKET=udarnik UDARNIK_UNIT=udarnik UDARNIK_ACCOUNTS="$real/.claude:$real/.claude-work"
  UDARNIK_FLEET="$real/.config/agentic/fleet.json" AGENTIC_FLEET="$real/.config/agentic/fleet.json"
  UDARNIK_SSH="$canary/bin/ssh" UDARNIK_MACHINE_ID=real-id AGENTIC_MACHINE_ID=real-id
  UDARNIK_ORDER_WORKER=claude-work UDARNIK_ORDER_INTERACTIVE=claude-work UDARNIK_HEADLESS_ENTRYPOINTS=none
  UDARNIK_POLL_SECONDS=1 UDARNIK_CLAUDE="$canary/bin/claude" UDARNIK_CLONE_SCOPE=on UDARNIK_LINKS=on
  UDARNIK_USAGE_FILE="$real/.cache/claude-statusline-usage-{key}.json" UDARNIK_SHARED_DIR="$real/.claude-shared"
  UDARNIK_PREFIX="$real/.local/share/udarnik" UDARNIK_CLOCK_OFFSET=987654 UDARNIK_FLEET_TAKEOVER=on
  UDARNIK_SHARE_WAIT=0 UDARNIK_VIA=real-host
)
[[ -z ${UDARNIK_TEST_NOW:-} ]] || poison+=(UDARNIK_TEST_NOW="$UDARNIK_TEST_NOW")

# ------------------------------------------------------------------ the tracer
tracer=none
run=(env -i "${poison[@]}" bash "$work/repo/tests/udarnik.sh")
if command -v strace >/dev/null 2>&1; then
  tracer=strace
  # The calls the LD_PRELOAD tracer sees: what opens, runs, creates, removes or renames a file (not stat or access,
  # which the shell uses to look a command up in PATH, where the poisoned folders come first). %process: the forks,
  # so every process of the battery is known, even one that never opens a file.
  run=(strace -f -qq -o "$work/trace"
    -e trace=open,openat,creat,execve,execveat,mkdir,mkdirat,unlink,unlinkat,rmdir,rename,renameat,renameat2,symlink,symlinkat,link,linkat,%process
    "${run[@]}")
elif command -v cc >/dev/null 2>&1; then
  cat >"$work/trace.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <dirent.h>
static int log_fd = -1;
static char preload[4096], logvar[4096];
__attribute__((constructor)) static void start(void) {
  const char *p = getenv("TRACE_FILES_LOG"), *l = getenv("LD_PRELOAD");
  if (p) { log_fd = (int)syscall(SYS_openat, AT_FDCWD, p, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
           snprintf(logvar, sizeof logvar, "TRACE_FILES_LOG=%s", p); }
  if (l) snprintf(preload, sizeof preload, "LD_PRELOAD=%s", l);
  if (log_fd >= 0 && log_fd < 200) { int high = (int)syscall(SYS_fcntl, log_fd, F_DUPFD_CLOEXEC, 200);
    if (high >= 0) { syscall(SYS_close, log_fd); log_fd = high; } }
}
static void note(const char *op, int dirfd, const char *path) {
  char line[8192], base[4096] = "";
  int saved = errno;
  if (log_fd < 0 || !path) { errno = saved; return; }
  if (path[0] != '/' && !(op[0] == 'e' && !strchr(path, '/'))) {  /* a command name to look up in PATH stays as is */
    if (dirfd == AT_FDCWD) { if (syscall(SYS_getcwd, base, sizeof base - 1) < 0) strcpy(base, "?"); }
    else { char link[64]; snprintf(link, sizeof link, "/proc/self/fd/%d", dirfd);
           long n = syscall(SYS_readlinkat, AT_FDCWD, link, base, sizeof base - 1); base[n > 0 ? n : 0] = 0; }
  }
  int n = snprintf(line, sizeof line, "%d %s %s%s%s\n", (int)getpid(), op, base, base[0] ? "/" : "", path);
  if (n > 0) syscall(SYS_write, log_fd, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1));
  errno = saved;
}
/* A new process: "<parent> fork <child>", so a process that never opens a file is still known as one of the battery's. */
static void note_child(pid_t child) {
  char line[64];
  int saved = errno;
  if (log_fd >= 0 && child > 0) {
    int n = snprintf(line, sizeof line, "%d fork %d\n", (int)getpid(), (int)child);
    if (n > 0) syscall(SYS_write, log_fd, line, (size_t)n);
  }
  errno = saved;
}
#define REAL(name) static __typeof__(name) *real_##name; if (!real_##name) real_##name = dlsym(RTLD_NEXT, #name)
pid_t fork(void) { REAL(fork); pid_t child = real_fork(); if (child > 0) note_child(child); return child; }
#define MODE_ARG mode_t mode = 0; if (flags & (O_CREAT | O_TMPFILE)) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
int open(const char *path, int flags, ...) { MODE_ARG REAL(open); note("open", AT_FDCWD, path); return real_open(path, flags, mode); }
int open64(const char *path, int flags, ...) { MODE_ARG REAL(open64); note("open", AT_FDCWD, path); return real_open64(path, flags, mode); }
int openat(int d, const char *path, int flags, ...) { MODE_ARG REAL(openat); note("open", d, path); return real_openat(d, path, flags, mode); }
int openat64(int d, const char *path, int flags, ...) { MODE_ARG REAL(openat64); note("open", d, path); return real_openat64(d, path, flags, mode); }
int __open_2(const char *path, int flags) { REAL(open); note("open", AT_FDCWD, path); return real_open(path, flags); }
int __open64_2(const char *path, int flags) { REAL(open64); note("open", AT_FDCWD, path); return real_open64(path, flags); }
int __openat_2(int d, const char *path, int flags) { REAL(openat); note("open", d, path); return real_openat(d, path, flags); }
int __openat64_2(int d, const char *path, int flags) { REAL(openat64); note("open", d, path); return real_openat64(d, path, flags); }
int creat(const char *path, mode_t mode) { REAL(creat); note("creat", AT_FDCWD, path); return real_creat(path, mode); }
FILE *fopen(const char *path, const char *m) { REAL(fopen); note("fopen", AT_FDCWD, path); return real_fopen(path, m); }
FILE *fopen64(const char *path, const char *m) { REAL(fopen64); note("fopen", AT_FDCWD, path); return real_fopen64(path, m); }
DIR *opendir(const char *path) { REAL(opendir); note("opendir", AT_FDCWD, path); return real_opendir(path); }
int mkdir(const char *path, mode_t mode) { REAL(mkdir); note("mkdir", AT_FDCWD, path); return real_mkdir(path, mode); }
int mkdirat(int d, const char *path, mode_t mode) { REAL(mkdirat); note("mkdir", d, path); return real_mkdirat(d, path, mode); }
int unlink(const char *path) { REAL(unlink); note("unlink", AT_FDCWD, path); return real_unlink(path); }
int unlinkat(int d, const char *path, int f) { REAL(unlinkat); note("unlink", d, path); return real_unlinkat(d, path, f); }
int rmdir(const char *path) { REAL(rmdir); note("rmdir", AT_FDCWD, path); return real_rmdir(path); }
int rename(const char *a, const char *b) { REAL(rename); note("rename", AT_FDCWD, a); note("rename", AT_FDCWD, b); return real_rename(a, b); }
int renameat(int da, const char *a, int db, const char *b) { REAL(renameat); note("rename", da, a); note("rename", db, b); return real_renameat(da, a, db, b); }
int renameat2(int da, const char *a, int db, const char *b, unsigned f) { REAL(renameat2); note("rename", da, a); note("rename", db, b); return real_renameat2(da, a, db, b, f); }
int symlink(const char *a, const char *b) { REAL(symlink); note("symlink", AT_FDCWD, b); return real_symlink(a, b); }
int symlinkat(const char *a, int d, const char *b) { REAL(symlinkat); note("symlink", d, b); return real_symlinkat(a, d, b); }
int link(const char *a, const char *b) { REAL(link); note("link", AT_FDCWD, a); note("link", AT_FDCWD, b); return real_link(a, b); }
/* Every exec keeps the tracer, even through `env -i`: the -f of strace. */
int execve(const char *path, char *const argv[], char *const envp[]) {
  REAL(execve);
  note("exec", AT_FDCWD, path);
  size_t n = 0; int has_preload = 0, has_log = 0;
  for (; envp && envp[n]; n++) { if (!strncmp(envp[n], "LD_PRELOAD=", 11)) has_preload = 1;
                                 if (!strncmp(envp[n], "TRACE_FILES_LOG=", 16)) has_log = 1; }
  char **env = malloc((n + 3) * sizeof *env);
  if (!env) return real_execve(path, argv, envp);
  size_t i = 0; for (; i < n; i++) env[i] = envp[i];
  if (!has_preload && preload[0]) env[i++] = preload;
  if (!has_log && logvar[0]) env[i++] = logvar;
  env[i] = NULL;
  int r = real_execve(path, argv, env); free(env); return r;
}
/* The execs that search PATH or take the environment of the process go through glibc's own execve: keep the tracer
   in environ first. */
static void keep(void) {
  if (preload[0] && !getenv("LD_PRELOAD")) putenv(preload);
  if (logvar[0] && !getenv("TRACE_FILES_LOG")) putenv(logvar);
}
int execv(const char *path, char *const argv[]) { REAL(execv); note("exec", AT_FDCWD, path); keep(); return real_execv(path, argv); }
int execvp(const char *file, char *const argv[]) { REAL(execvp); note("exec", AT_FDCWD, file); keep(); return real_execvp(file, argv); }
int execvpe(const char *file, char *const argv[], char *const envp[]) {
  REAL(execvpe); note("exec", AT_FDCWD, file);
  size_t n = 0; for (; envp && envp[n]; n++) ;
  char **env = malloc((n + 3) * sizeof *env); if (!env) return real_execvpe(file, argv, envp);
  size_t i = 0; for (; i < n; i++) env[i] = envp[i];
  if (preload[0]) env[i++] = preload;
  if (logvar[0]) env[i++] = logvar;
  env[i] = NULL; return real_execvpe(file, argv, env);
}
#include <spawn.h>
static char **with_tracer(char *const envp[]) {
  size_t n = 0; for (; envp && envp[n]; n++) ;
  char **env = malloc((n + 3) * sizeof *env); if (!env) return (char **)envp;
  size_t i = 0; for (; i < n; i++) env[i] = envp[i];
  if (preload[0]) env[i++] = preload;
  if (logvar[0]) env[i++] = logvar;
  env[i] = NULL; return env;
}
int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at,
                char *const argv[], char *const envp[]) {
  REAL(posix_spawn); note("exec", AT_FDCWD, path); pid_t child = 0;
  int r = real_posix_spawn(&child, path, fa, at, argv, with_tracer(envp));
  if (r == 0) { note_child(child); if (pid) *pid = child; }
  return r;
}
int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *fa, const posix_spawnattr_t *at,
                 char *const argv[], char *const envp[]) {
  REAL(posix_spawnp); note("exec", AT_FDCWD, file); pid_t child = 0;
  int r = real_posix_spawnp(&child, file, fa, at, argv, with_tracer(envp));
  if (r == 0) { note_child(child); if (pid) *pid = child; }
  return r;
}
C
  if cc -shared -fPIC -O1 -o "$work/trace.so" "$work/trace.c" -ldl 2>"$work/trace.cc.err"; then
    tracer=preload
    run=(env LD_PRELOAD="$work/trace.so" TRACE_FILES_LOG="$work/trace" "${run[@]}")
  else
    cat "$work/trace.cc.err" >&2
  fi
fi

# ------------------------------------------------------------------ the run
printf 'running the battery in the poisoned environment (tracer: %s)\n' "$tracer"
# From an empty folder of the run: a relative path opened before the battery's first `cd` is not one of the checkout.
mkdir -p "$work/start"
(cd "$work/start" && exec "${run[@]}") >"$work/battery.out" 2>&1
status=$?
tail -1 "$work/battery.out"
grep -E '^not ok' "$work/battery.out" >&2 || true

check 'the battery passes in the poisoned environment' test "$status" -eq 0
after=$(fingerprint)
check 'the poisoned home and state (an account out, a log of ISO lines, a fleet, a usage file) are unchanged' \
  test "$before" == "$after"
check 'the tmux server named as the real one has the same windows, no new one' test "$windows_before" == "$(tmux_windows)"
# The shell that starts the battery reads BASH_ENV before the first line of it (that line drops it): that one is the
# caller's, not the battery's.
grep -vxF "BASH_ENV $work/repo/tests/udarnik.sh" "$canary/calls" >"$canary/calls.battery" 2>/dev/null || true
check 'no canary ran (udarnik, claude, ssh, systemctl, systemd-run of the PATH, BASH_ENV in a process of the battery)' \
  test ! -s "$canary/calls.battery"
[[ ! -s $canary/calls.battery ]] || cat "$canary/calls.battery" >&2

if [[ $tracer == none ]]; then
  printf 'skipped - no strace and no cc: the file trace was not taken\n'
else
  # One record per call, "<pid> <path>", and the processes of the battery: every pid that made a call or was forked
  # by one that did. strace: <pid> syscall("path", ...) = result, and the forks are clone/fork/vfork = <child>; a
  # failed exec is a lookup of the command in PATH (the poisoned folders come first in it), not a use of the file.
  # Only absolute paths are judged: strace prints a relative one as given (the battery starts in an empty folder of
  # the run, then works in its own). The tracer: <pid> op path, and <pid> fork <child>.
  if [[ $tracer == strace ]]; then
    awk '/^[0-9]+ +execve(at)?\(.*= -1 E/ { next }
      { pid = $1; rest = $0
        while (match(rest, /"\/[^"]*"/)) { print pid, substr(rest, RSTART + 1, RLENGTH - 2); rest = substr(rest, RSTART + RLENGTH) } }' \
      "$work/trace" >"$work/records"
    awk '{ print $1 } /(clone3?|v?fork)(\(| resumed>).*= [0-9]+$/ { print $NF }' "$work/trace" | sort -u >"$work/pids"
  else
    awk '$2 != "fork" { pid = $1; $1 = ""; $2 = ""; sub(/^  /, ""); print pid, $0 }' "$work/trace" >"$work/records"
    awk '{ print $1 } $2 == "fork" { print $3 }' "$work/trace" | sort -u >"$work/pids"
  fi
  paths=$(cut -d' ' -f2- "$work/records")
  # /run/systemd/userdb: the system's user database (a name lookup of the uid), read by the C library.
  outside=$(grep -E '^/' <<<"$paths" | grep -vE '^/(tmp|proc|dev|sys|usr|etc|lib|lib64|bin|sbin|run/systemd/userdb)(/|$)' |
    sort | uniq -c | sort -rn)
  printf 'trace: %s calls, %s distinct paths, %s processes\n' "$(grep -c . <<<"$paths")" "$(sort -u <<<"$paths" | grep -c .)" \
    "$(grep -c . "$work/pids")"
  check 'no file outside /tmp, /proc, /dev and the system folders was opened, run, created, removed or renamed' \
    test -z "$outside"
  [[ -z $outside ]] || head -40 <<<"$outside" >&2

  # /proc/<pid> of a process that is not the battery's (a real worker, the real service, the shell that started the
  # run): its command line, its environment (a token), its folder. /proc/self and /proc/thread-self are not a pid.
  # One exception: tmux, when it opens a pane, reads /proc/1/cgroup (the init of the system, not a process of the
  # owner) to place the pane's process in its own scope.
  foreign=$(awk 'NR == FNR { mine[$1] = 1; next }
    match($2, /^\/proc\/[0-9]+(\/|$)/) { pid = substr($2, 7); sub(/\/.*/, "", pid)
      if (!(pid in mine) && $2 != "/proc/1/cgroup") print $2 }' "$work/pids" "$work/records" |
    sed -E 's#^/proc/[0-9]+#/proc/<pid>#; s#/task/[0-9]+#/task/<tid>#' | sort | uniq -c | sort -rn)
  check 'no /proc/<pid> of a process that is not the battery'"'"'s was opened (cmdline, environ, cwd, stat...)' \
    test -z "$foreign"
  [[ -z $foreign ]] || head -20 <<<"$foreign" >&2

  # The poisoned "real" machine is under /tmp, so the check above allows it: nothing of it may be touched. One
  # exception: the shell that starts the battery (the first process of the trace) reads BASH_ENV, which appends to
  # the canaries' calls, before the first line of the battery (the line that drops it) runs.
  first=$(head -1 "$work/records" | cut -d' ' -f1)
  poisoned=$(awk -v first="$first" -v real="$real/" -v tmux_dir="$work/real-tmux/" -v canary="$canary/" '
    { pid = $1; path = substr($0, length($1) + 2)
      if (index(path "/", real) != 1 && index(path "/", tmux_dir) != 1 && index(path "/", canary) != 1) next
      if (pid == first && (path == canary "bash_env" || path == canary "calls")) next
      print path }' "$work/records" | sort | uniq -c | sort -rn)
  check 'nothing of the poisoned home, state, tmux folder or canaries was opened, run, created or removed' \
    test -z "$poisoned"
  [[ -z $poisoned ]] || head -20 <<<"$poisoned" >&2
  check 'the trace saw the battery work in its own folder (it is not empty)' grep -q '/state/accounts/' <<<"$paths"
fi
exit "$failed"
