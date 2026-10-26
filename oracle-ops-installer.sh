#!/bin/bash
# Oracle OPS Installer
#
# A menu-driven wrapper that installs, upgrades or de-installs Oracle OPS and updates its stored WebLogic credential.
# It contains no Oracle OPS code and none of Oracle OPS's installation logic: for each action it downloads ONE pinned,
# verified Oracle OPS release from the private repository into a root-only staging directory, runs the Oracle OPS
# script made for that action, verifies the result, and removes the staged source and the access token again.
# Oracle APEX is out of scope: this installer never installs, configures or deploys anything APEX-related.
#
#   Action                 Oracle OPS script it runs (from the pinned release)
#   Install Oracle OPS     deploy/scripts/deploy-oracle-ops.sh --home <dir>     (interactive setup assistant)
#   Update credentials     deploy/scripts/manage-app-credentials.sh              (WebLogic credential; interactive)
#   Upgrade Oracle OPS     deploy/scripts/install-release.sh --home --user --group service/   (or activate-release.sh)
#   De-install Oracle OPS  deploy/scripts/service-identity.sh retire --home <dir> --apply      (renames, deletes nothing)
#
# Usage:   sudo bash oracle-ops-installer.sh [--java-archive FILE]
#          bash oracle-ops-installer.sh --help | --version
#
# Exit status: 0 done, or nothing to do | 1 the action failed | 2 cannot run as invoked | 3 prerequisites missing |
#              4 source access or verification failed | 5 cancelled by the operator | 6 the action does not apply to
#              this host (nothing changed) | 129/130/143 interrupted
#
# Design notes for maintainers: README.md, SECURITY.md and docs/DEVELOPER.md. This file is also sourced by the test
# suite (tests/); everything runs from main(). Functions marked "seam" wrap host-specific actions so tests can replace
# them, and the "Host locations" globals are reassigned by the tests after sourcing (they are NOT read from the
# environment).

set +x +v   # never trace: a trace would print the access token the moment it is handled

INSTALLER_VERSION="0.1.0"

# ---- Pinned Oracle OPS release. Changed only by a reviewed installer release (docs/DEVELOPER.md). ----------------------
OPS_REPO_URL="https://github.com/Moon2998/oracle-ops.git"
OPS_COMMIT="5a13cf4456c4ed3361c74aaa39e5d36b257af894"   # full commit id; nothing else is ever checked out
OPS_VERSION="0.1.5"                                      # service/VERSION at OPS_COMMIT
SUPPORTED_PLATFORMS="ol:7"                               # /etc/os-release ID:major; must be in the release's jdk.platforms
SUPPORTED_ARCH="x86_64"
# git's credential prompts for OPS_REPO_URL, answered by the temporary askpass helper (and nothing else is answered).
GIT_HOST_URL="https://github.com"
GIT_USERNAME="x-access-token"
GIT_PASSWORD_URL="https://x-access-token@github.com"

# ---- Host locations and limits (plain globals; tests reassign them after sourcing) -----------------------------------
STATE_DIR="/var/lib/oracle-ops-installer"   # root-only; per-run staging directories run.XXXXXXXX live here
LOG_DIR="/var/log/oracle-ops-installer"     # root-only protected logs
AUTH_BASE="/run"                            # RAM-backed (tmpfs) home of the short-lived token file, when safe
CRED_DIR="/etc/oracle-ops"                  # Oracle OPS's credential directory: read-only checks here, never written
UNIT_FILE="/etc/systemd/system/oracle-ops.service"
UNIT_NAME="oracle-ops.service"
LOGROTATE_DIR="/etc/logrotate.d"
OS_RELEASE_FILE="/etc/os-release"
SYSTEMD_RUN_DIR="/run/systemd/system"
DEFAULT_HOME="/u01/oracle_ops_runtime"     # Oracle OPS's documented default installation directory
SAFE_PATH="/usr/sbin:/usr/bin:/sbin:/bin"
ADMIN_UID=0
ROOT_HOME="/root"                           # HOME given to the Oracle OPS scripts (main() reads root's entry)
HOME_FORBIDDEN="/ /etc /proc /sys /dev /run /boot /bin /sbin /lib /lib64 /usr /tmp /var/tmp /var/lib/oracle-ops-installer /etc/oracle-ops"
LOG_KEEP=20
MIN_STAGE_MB=200
GIT_LS_REMOTE_TIMEOUT=120
GIT_CLONE_TIMEOUT=900
PKG_TIMEOUT=1800
JAR_VERSION_ENTRY="com/oracleops/core/version.properties"
SERVICE_LOG_REL="logs/oracle-ops.log"
DB_HEALTHY_LINE="Database connectivity startup health check: HEALTHY"
MARKER_NAME=".oracle-ops-installer-run"
MARKER_TEXT="oracle-ops-installer-run"
# Environment variables passed through to child processes (everything else is removed; see clean_env_exec).
ENV_KEEP="TERM http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY"
# Tools needed by the installer and by the Oracle OPS scripts it runs (their own preflights check them again).
REQUIRED_TOOLS="git curl unzip tar gzip sha256sum flock setpriv find readlink stat mktemp timeout df awk sed grep install cmp cp chmod chown chgrp mkdir rm mv ln tee env getent systemctl tr cut sort head tail date id uname stty"
BOOTSTRAP_TOOLS="id mkdir chmod stat mktemp date flock rm sed tr dirname basename"

# ---- State ---------------------------------------------------------------------------------------------------------------
OPERATION="installer run"
STAGE_TOTAL=0
LOG_FILE=""
RUN_DIR=""
AUTH_DIR=""
OPS_SRC=""
TOKEN=""              # NEVER exported, never passed as an argument, never printed or logged
LOCK_FD=""
JAVA_ARCHIVE=""
FAIL_REASON=""
SUCCESS_TEXT=""
CLEANUP_PROBLEMS=""
CAPTURE=""
INST_HOME=""; INST_USER=""; INST_GROUP=""; INST_RELEASE=""; INST_COMMIT=""; INST_ACTIVE=""
TARGET_HOME=""

# ---------------------------------------------------------------------------------------------------------------------------
# Seams
# ---------------------------------------------------------------------------------------------------------------------------

is_root() { [ "$(id -u)" -eq 0 ]; }
stdin_is_tty() { [ -t 0 ]; }
host_arch() { uname -m; }
is_tmpfs() { [ "$(stat -f -c %T "$1" 2>/dev/null)" = "tmpfs" ]; }
service_active() { systemctl is-active --quiet "$UNIT_NAME"; }
root_home() { getent passwd root 2>/dev/null | cut -d: -f6; }

# ---------------------------------------------------------------------------------------------------------------------------
# Output and protected logging
# ---------------------------------------------------------------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Removes secrets and terminal control sequences from a stream before it reaches the log: the literal token (bash
# expansion, so the token never becomes an argument of another program), anything shaped like a GitHub token, the
# user-info part of URLs (proxy or credential-bearing URLs), ANSI escape sequences and other control characters.
sanitize_stream() {
  local line esc
  esc="$(printf '\033')"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$TOKEN" ]; then line="${line//"$TOKEN"/[REDACTED]}"; fi
    printf '%s\n' "$line"
  done | sed -r \
      -e "s/${esc}\\[[0-9;?]*[A-Za-z]//g" \
      -e 's/gh[pousr]_[A-Za-z0-9]{16,}/[REDACTED]/g' \
      -e 's/github_pat_[A-Za-z0-9_]{16,}/[REDACTED]/g' \
      -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
    | tr -d '\000-\010\013-\037\177'
}

log() {
  [ -n "$LOG_FILE" ] || return 0
  printf '%s %s\n' "$(now_utc)" "$*" | sanitize_stream >> "$LOG_FILE" 2>/dev/null || true
}

stage() {
  say "[$1/$STAGE_TOTAL] $2"
  log "== stage $1/$STAGE_TOTAL: $2"
}

# run_quiet <description> <command...>: stdin closed, all output to the protected log (sanitized). The raw output stays in
# $CAPTURE (inside the root-only run directory) until the next call, for failure classification. Returns the status.
run_quiet() {
  local desc="$1" rc=0
  shift
  [ -n "$RUN_DIR" ] || finish 1 "internal error: no staging directory"
  log "run: $desc"
  CAPTURE="$RUN_DIR/capture.out"
  "$@" < /dev/null > "$CAPTURE" 2>&1 || rc=$?
  sanitize_stream < "$CAPTURE" | sed 's/^/    | /' >> "$LOG_FILE" || log "WARNING: the output of '$desc' could not be written to the log"
  log "exit status $rc: $desc"
  return "$rc"
}

# run_interactive <description> <command...>: an Oracle OPS tool that talks to the operator. It keeps the terminal on
# stdin; its output is shown AND recorded (sanitized) in the log afterwards. Returns the tool's status.
run_interactive() {
  local desc="$1" rc=0 out="$RUN_DIR/interactive.out"
  shift
  [ -n "$RUN_DIR" ] || finish 1 "internal error: no staging directory"
  log "run (interactive, shown to the operator): $desc"
  : > "$out"
  if "$@" 2>&1 | tee -a "$out"; then rc=0; else rc="${PIPESTATUS[0]}"; fi
  sanitize_stream < "$out" | sed 's/^/    | /' >> "$LOG_FILE" || log "WARNING: the output of '$desc' could not be written to the log"
  rm -f -- "$out"
  log "exit status $rc: $desc"
  return "$rc"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Child processes: a scrubbed environment, never the token
# ---------------------------------------------------------------------------------------------------------------------------

# Only ever called inside a subshell: removes every exported variable except ENV_KEEP (so BASH_ENV, GIT_*, JAVA_*,
# LD_* and the like cannot reach a child), sets PATH/HOME/LC_ALL, then replaces the subshell with the command. Building
# the environment here, rather than with `env NAME=value`, keeps values such as proxy URLs out of any argument list.
CHILD_HOME=""
clean_env_exec() {
  local v
  for v in $(compgen -e); do
    case " $ENV_KEEP " in *" $v "*) ;; *) unset "$v" 2>/dev/null || true ;; esac
  done
  export PATH="$SAFE_PATH" HOME="$CHILD_HOME" LC_ALL=C
  exec "$@"
}

# The installer's own environment gets the same treatment at start-up, so the commands it runs directly (systemctl, unzip,
# yum, ...) inherit only ENV_KEEP too. sudo normally resets the environment already; this also covers a root login shell.
scrub_environment() {
  local v
  for v in $(compgen -e); do
    case " $ENV_KEEP " in *" $v "*) ;; *) unset "$v" 2>/dev/null || true ;; esac
  done
  export PATH="$SAFE_PATH" LC_ALL=C
}

# git_net <timeout> <git arguments...>: a network git command authenticated only through the askpass helper. HOME is an
# empty directory and GIT_CONFIG_NOSYSTEM=1, so no user or system git configuration (and no credential helper that could
# store the token) is read; the user's git configuration and credentials are never touched.
git_net() {
  local t="$1"
  shift
  ( CHILD_HOME="$RUN_DIR/githome"
    export GIT_ASKPASS="$AUTH_DIR/askpass" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
    ENV_KEEP="$ENV_KEEP GIT_ASKPASS GIT_CONFIG_NOSYSTEM GIT_TERMINAL_PROMPT"
    clean_env_exec timeout --foreground "$t" git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=60 -c transfer.fsckObjects=true "$@" )
}

# git_local <git arguments...>: a local git command inside the staged source (no network, no askpass).
git_local() {
  ( cd "$OPS_SRC" || exit 1
    CHILD_HOME="$RUN_DIR/githome"
    export GIT_CONFIG_NOSYSTEM=1
    ENV_KEEP="$ENV_KEEP GIT_CONFIG_NOSYSTEM"
    clean_env_exec git "$@" )
}

# ops_run <script> <arguments...>: an Oracle OPS script from the staged, verified release, with the umask Oracle OPS
# expects of root (022) and no TMPDIR (its database check stages files in /tmp for the service account).
ops_run() {
  local script="$1"
  shift
  ( umask 022
    CHILD_HOME="$ROOT_HOME"
    clean_env_exec bash "$OPS_SRC/deploy/scripts/$script" "$@" )
}

# pkg_run <packages...>: the operating system's package manager with a fixed command; the package names come only from
# tool_package() below, never from input.
pkg_run() {
  ( CHILD_HOME="$ROOT_HOME"
    clean_env_exec timeout --foreground "$PKG_TIMEOUT" yum -y install "$@" )
}

# ---------------------------------------------------------------------------------------------------------------------------
# Ending a run: one exit path, cleanup always attempted, the primary outcome never replaced by a cleanup problem
# ---------------------------------------------------------------------------------------------------------------------------

finish() {   # finish <exit status> [reason]
  FAIL_REASON="${2:-}"
  exit "$1"
}

die_early() {  # before logging exists: a short message, no secret, no log reference
  printf 'Oracle OPS Installer: %s\n' "$1" >&2
  exit "$2"
}

# Removes a directory only if it is exactly the path this run recorded, is a real directory and carries this run's marker.
remove_own_dir() {
  local d="$1"
  [ -n "$d" ] || return 0
  [ -e "$d" ] || [ -L "$d" ] || return 0
  if [ -L "$d" ] || [ ! -d "$d" ] || [ ! -f "$d/$MARKER_NAME" ]; then
    CLEANUP_PROBLEMS="$CLEANUP_PROBLEMS $d"
    log "cleanup: NOT removing $d (not a directory carrying this run's marker)"
    return 0
  fi
  if rm -rf --one-file-system -- "$d" && [ ! -e "$d" ]; then
    log "cleanup: removed $d"
  else
    CLEANUP_PROBLEMS="$CLEANUP_PROBLEMS $d"
    log "cleanup: FAILED to remove $d"
  fi
}

destroy_auth() {
  if [ -n "$AUTH_DIR" ]; then
    rm -f -- "$AUTH_DIR/token" 2>/dev/null || true
    [ ! -e "$AUTH_DIR/token" ] || CLEANUP_PROBLEMS="$CLEANUP_PROBLEMS $AUTH_DIR/token"
    remove_own_dir "$AUTH_DIR"
    case " $CLEANUP_PROBLEMS " in *" $AUTH_DIR "*) ;; *) AUTH_DIR="" ;; esac
  fi
  TOKEN=""
}

cleanup() {
  destroy_auth
  if [ -n "$RUN_DIR" ]; then
    remove_own_dir "$RUN_DIR"
    case " $CLEANUP_PROBLEMS " in *" $RUN_DIR "*) ;; *) RUN_DIR="" ;; esac
  fi
}

report() {
  local rc="$1" what="Oracle OPS $OPERATION"
  log "outcome: exit status $rc${FAIL_REASON:+ — $FAIL_REASON}"
  case "$rc" in
    0)
      [ -z "$SUCCESS_TEXT" ] || { echo; printf '%s\n' "$SUCCESS_TEXT"; }
      ;;
    5)
      echo; say "Cancelled${FAIL_REASON:+: $FAIL_REASON}."
      ;;
    6)
      echo; say "${FAIL_REASON:-This action does not apply to this host}."
      say "Nothing was changed."
      ;;
    129|130|143)
      echo; say "$what was interrupted."
      ;;
    *)
      echo; say "$what failed."
      [ -z "$FAIL_REASON" ] || say "Reason: $FAIL_REASON."
      ;;
  esac
  if [ "$rc" != 0 ] && [ -n "$LOG_FILE" ]; then
    echo
    say "Review the administrator installation log for details:"
    say "  $LOG_FILE"
  elif [ "$rc" = 0 ] && [ -n "$LOG_FILE" ] && [ -n "$SUCCESS_TEXT" ]; then
    say "Installation log: $LOG_FILE"
  fi
  if [ -n "$CLEANUP_PROBLEMS" ]; then
    log "WARNING: cleanup incomplete:$CLEANUP_PROBLEMS"
    echo
    say "Warning: temporary installer files could not be removed:$CLEANUP_PROBLEMS"
    say "Remove them as root after review. They may contain the private Oracle OPS source."
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  if stdin_is_tty; then stty echo 2>/dev/null; fi
  cleanup
  report "$rc"
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Start-up: protected log, lock, staging directory
# ---------------------------------------------------------------------------------------------------------------------------

# ensure_private_dir <dir>: <dir> must be (or is created as) a real directory owned by the administrative account, mode
# 0700, under a parent owned by that account and not writable by group or other. Nothing is followed through a link.
ensure_private_dir() {
  local d="$1" p mode
  p="$(dirname "$d")"
  if [ ! -d "$p" ] || [ -L "$p" ] || [ "$(stat -c %u "$p")" != "$ADMIN_UID" ]; then
    echo "$p must be a real directory owned by root"; return 1
  fi
  mode="$(stat -c %a "$p")"
  if [ $((8#$mode & 8#022)) -ne 0 ]; then echo "$p is writable by group or other users (mode $mode)"; return 1; fi
  if [ -L "$d" ]; then echo "$d is a symbolic link"; return 1; fi
  if [ -e "$d" ]; then
    [ -d "$d" ] || { echo "$d exists and is not a directory"; return 1; }
    [ "$(stat -c %u "$d")" = "$ADMIN_UID" ] || { echo "$d is not owned by root"; return 1; }
    chmod 0700 "$d" || { echo "cannot set the mode of $d"; return 1; }
  else
    mkdir -m 0700 "$d" || { echo "cannot create $d"; return 1; }
  fi
}

init_logging() {
  local msg stamp
  msg="$(ensure_private_dir "$LOG_DIR")" || die_early "cannot use the log directory: $msg. Resolve this as root, then run the installer again." 1
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  LOG_FILE="$LOG_DIR/oracle-ops-installer-$stamp-$$.log"
  ( umask 077; : > "$LOG_FILE" ) || die_early "cannot create the log file in $LOG_DIR" 1
  chmod 0600 "$LOG_FILE"
  log "Oracle OPS Installer $INSTALLER_VERSION; pinned Oracle OPS $OPS_VERSION ($OPS_COMMIT); pid $$"
  prune_logs
}

# Keeps the newest LOG_KEEP installer logs; only regular files with this installer's own name pattern are ever removed.
prune_logs() {
  local f n=0
  while IFS= read -r f; do
    n=$((n + 1))
    [ "$n" -gt "$LOG_KEEP" ] || continue
    case "$f" in oracle-ops-installer-[0-9]*T[0-9]*Z-[0-9]*.log) ;; *) continue ;; esac
    if [ -f "$LOG_DIR/$f" ] && [ ! -L "$LOG_DIR/$f" ]; then rm -f -- "$LOG_DIR/$f" && log "removed old log $f"; fi
  done < <(find "$LOG_DIR" -mindepth 1 -maxdepth 1 -type f -name 'oracle-ops-installer-*.log' -printf '%f\n' | sort -r)
}

# The state directory holds only the lock file and this installer's run directories. Every run.* carrying the marker is
# a leftover of an interrupted run (the lock proves no other run is active) and is removed; anything else stops the run.
init_state() {
  local msg e
  msg="$(ensure_private_dir "$STATE_DIR")" || finish 1 "cannot use the staging directory: $msg (resolve this as root after review)"
  exec {LOCK_FD}>>"$STATE_DIR/.lock" || finish 1 "cannot open the lock file in $STATE_DIR"
  flock -n "$LOCK_FD" || finish 1 "another run of the Oracle OPS Installer is in progress"
  while IFS= read -r e; do
    case "$e" in
      .lock) ;;
      run.*)
        if [ -d "$STATE_DIR/$e" ] && [ ! -L "$STATE_DIR/$e" ] && [ -f "$STATE_DIR/$e/$MARKER_NAME" ]; then
          log "removing the staging directory of an earlier, interrupted run: $STATE_DIR/$e"
          rm -rf --one-file-system -- "${STATE_DIR:?}/$e" || finish 1 "cannot remove the leftover staging directory $STATE_DIR/$e"
        else
          finish 1 "unexpected entry $STATE_DIR/$e (not created by this installer). Review and remove it as root, then run the installer again"
        fi ;;
      *) finish 1 "unexpected entry $STATE_DIR/$e (not created by this installer). Review and remove it as root, then run the installer again" ;;
    esac
  done < <(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -printf '%f\n')
  # Leftover token directories of interrupted runs (only ours: marker present; /run is emptied at every boot anyway).
  ensure_private_dir_parent_ok "$AUTH_BASE" && while IFS= read -r e; do
    if [ -d "$e" ] && [ ! -L "$e" ] && [ -f "$e/$MARKER_NAME" ]; then
      rm -rf --one-file-system -- "$e" && log "removed a leftover token directory of an interrupted run: $e"
    fi
  done < <(find "$AUTH_BASE" -mindepth 1 -maxdepth 1 -name 'oracle-ops-installer.*' -print 2>/dev/null)
  RUN_DIR="$(mktemp -d "$STATE_DIR/run.XXXXXXXX")" || finish 1 "cannot create a staging directory in $STATE_DIR"
  printf '%s %s %s\n' "$MARKER_TEXT" "$BASHPID" "$(now_utc)" > "$RUN_DIR/$MARKER_NAME"
  mkdir -m 0700 "$RUN_DIR/githome"
  log "staging directory: $RUN_DIR"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------------------------------------------------------------

read_line() {  # read_line <variable>: one trimmed line from stdin; false at end of input
  local _l
  IFS= read -r _l || return 1
  _l="${_l#"${_l%%[![:space:]]*}"}"
  _l="${_l%"${_l##*[![:space:]]}"}"
  printf -v "$1" '%s' "$_l"
}

# confirm_yes <question>: true only for "yes" (any case). Anything else, or the end of input, is a no.
confirm_yes() {
  local a
  printf '      %s Type "yes" to continue: ' "$1"
  read_line a || { echo; return 1; }
  [ "$(printf '%s' "$a" | tr 'A-Z' 'a-z')" = "yes" ]
}

# choose <variable> <prompt> <allowed values...>: up to three attempts.
choose() {
  local var="$1" prompt="$2" a v attempt
  shift 2
  for attempt in 1 2 3; do
    printf '%s' "$prompt"
    read_line a || { echo; finish 5 "no choice was entered"; }
    for v in "$@"; do
      if [ "$a" = "$v" ]; then printf -v "$var" '%s' "$a"; return 0; fi
    done
    say "      Please enter one of: $*"
  done
  finish 2 "no valid choice after three attempts"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Validation helpers (Oracle OPS validates everything again; these keep the installer's own decisions safe)
# ---------------------------------------------------------------------------------------------------------------------------

valid_home() {
  local h="$1" f
  [[ "$h" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
  [ "${#h}" -le 200 ] || return 1
  case "$h/" in */../*|*/./*|*//*) return 1 ;; esac
  for f in $HOME_FORBIDDEN; do
    [ "$h" != "$f" ] || return 1
    [ "$f" = "/" ] || case "$h/" in "$f"/*) return 1 ;; esac
  done
  return 0
}

valid_account_name() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_.@-]{0,63}$ ]]; }

commit_matches_pin() {  # the build stamps an abbreviated commit id (at least 7 hex digits)
  [[ "$1" =~ ^[0-9a-f]{7,40}$ ]] && [ "${OPS_COMMIT#"$1"}" != "$OPS_COMMIT" ]
}

host_platform() {
  local id ver
  [ -r "$OS_RELEASE_FILE" ] || { echo "unknown"; return 0; }
  id="$(sed -n 's/^ID=//p' "$OS_RELEASE_FILE" | head -n 1 | tr -d '"'"'")"
  ver="$(sed -n 's/^VERSION_ID=//p' "$OS_RELEASE_FILE" | head -n 1 | tr -d '"'"'")"
  printf '%s:%s' "${id:-unknown}" "${ver%%.*}"
}

in_list() {  # in_list <word> <comma/space separated list>
  local w
  for w in ${2//,/ }; do [ "$w" = "$1" ] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------------------------------------------------------
# Prerequisites (derived from the Oracle OPS scripts' own preflight lists; docs/DEVELOPER.md)
# ---------------------------------------------------------------------------------------------------------------------------

tool_package() {
  case "$1" in
    git|curl|unzip|tar|gzip|sed|grep) echo "$1" ;;
    flock|setpriv) echo util-linux ;;
    find) echo findutils ;;
    awk) echo gawk ;;
    cmp) echo diffutils ;;
    getent) echo glibc-common ;;
    sha256sum|readlink|stat|mktemp|timeout|df|install|cp|chmod|chown|chgrp|mkdir|rm|mv|ln|tee|env|tr|cut|sort|head|tail|date|id|uname|stty) echo coreutils ;;
    *) echo "" ;;
  esac
}

MISSING_PKGS=""
MISSING_DESC=""
UNFIXABLE=""
scan_prerequisites() {
  local t p platform avail
  MISSING_PKGS=""; MISSING_DESC=""; UNFIXABLE=""
  platform="$(host_platform)"
  in_list "$platform" "$SUPPORTED_PLATFORMS" || UNFIXABLE="$UNFIXABLE"$'\n'"      - operating system $platform is not supported (supported: Oracle Linux 7)"
  [ "$(host_arch)" = "$SUPPORTED_ARCH" ] || UNFIXABLE="$UNFIXABLE"$'\n'"      - processor architecture $(host_arch) is not supported (supported: $SUPPORTED_ARCH)"
  [ -d "$SYSTEMD_RUN_DIR" ] || UNFIXABLE="$UNFIXABLE"$'\n'"      - systemd is not running (Oracle OPS runs as a systemd service)"
  for t in $REQUIRED_TOOLS; do
    command -v "$t" >/dev/null 2>&1 && continue
    p="$(tool_package "$t")"
    if [ -z "$p" ]; then
      UNFIXABLE="$UNFIXABLE"$'\n'"      - $t is missing and cannot be installed by this installer"
    else
      in_list "$p" "$MISSING_PKGS" || MISSING_PKGS="$MISSING_PKGS $p"
      MISSING_DESC="$MISSING_DESC"$'\n'"      - $t (package $p)"
    fi
  done
  if [ ! -d "$LOGROTATE_DIR" ]; then
    in_list logrotate "$MISSING_PKGS" || MISSING_PKGS="$MISSING_PKGS logrotate"
    MISSING_DESC="$MISSING_DESC"$'\n'"      - logrotate (package logrotate)"
  fi
  avail="$(df -Pk "$STATE_DIR" 2>/dev/null | awk 'NR==2 { print int($4 / 1024) }')"
  if [ -n "$avail" ] && [ "$avail" -lt "$MIN_STAGE_MB" ]; then
    UNFIXABLE="$UNFIXABLE"$'\n'"      - only ${avail} MB free for the temporary download in $STATE_DIR (${MIN_STAGE_MB} MB needed)"
  fi
  MISSING_PKGS="${MISSING_PKGS# }"
  log "prerequisites: platform=$platform arch=$(host_arch) missing_packages='${MISSING_PKGS}' unfixable='${UNFIXABLE//$'\n'/ }'"
}

check_prerequisites() {
  local c p
  scan_prerequisites
  if [ -n "$UNFIXABLE" ]; then
    say "      This system does not meet the requirements of Oracle OPS:$UNFIXABLE"
    finish 3 "unsupported system or missing requirement that the installer cannot provide"
  fi
  [ -n "$MISSING_PKGS" ] || { log "prerequisites: all present"; return 0; }
  for p in $MISSING_PKGS; do
    [[ "$p" =~ ^[a-z0-9][a-z0-9._+-]*$ ]] || finish 1 "internal error: invalid package name"
  done
  say "      Missing prerequisites:$MISSING_DESC"
  if command -v yum >/dev/null 2>&1; then
    say "      1) Install them now with yum"
    say "      2) I will install them myself"
    choose c "      Choose 1 or 2: " 1 2
  else
    c=2
  fi
  if [ "$c" = 2 ]; then
    say "      Install the missing packages as root, then run the installer again:"
    say "        yum install -y $MISSING_PKGS"
    finish 3 "missing prerequisites ($MISSING_PKGS) — manual installation chosen"
  fi
  say "      Installing: $MISSING_PKGS"
  # shellcheck disable=SC2086  # deliberate word splitting: validated, fixed package names
  run_quiet "yum -y install $MISSING_PKGS" pkg_run $MISSING_PKGS || finish 3 "the package manager could not install: $MISSING_PKGS"
  scan_prerequisites
  if [ -n "$MISSING_PKGS" ] || [ -n "$UNFIXABLE" ]; then
    finish 3 "prerequisites still missing after the installation attempt: ${MISSING_PKGS:-see log}"
  fi
  log "prerequisites: all present after installation"
}

# ---------------------------------------------------------------------------------------------------------------------------
# The existing installation (read-only)
# ---------------------------------------------------------------------------------------------------------------------------

unit_value() { sed -n "s/^$1=//p" "$UNIT_FILE" 2>/dev/null | head -n 1; }
unit_home() { sed -n 's/^Environment=ORACLE_OPS_HOME=//p' "$UNIT_FILE" 2>/dev/null | head -n 1; }

current_release() {  # the version `current` selects, if it is a link into <home>/releases/
  local h="$1" target base
  [ -L "$h/current" ] || return 0
  target="$(readlink -f "$h/current" 2>/dev/null)" || return 0
  base="$(readlink -f "$h")/releases/"
  case "$target" in "$base"?*) target="${target#"$base"}"; [ "${target#*/}" = "$target" ] && printf '%s' "$target" ;; esac
}

jar_commit() {  # the commit stamped into a deployed release by Oracle OPS's build
  local jar="$1/releases/$2/oracle-ops.jar"
  [ -f "$jar" ] && [ ! -L "$jar" ] || return 0
  unzip -p "$jar" "$JAR_VERSION_ENTRY" 2>/dev/null | sed -n 's/^build\.gitCommit=//p' | head -n 1 | tr -d '\r'
}

describe_installation() {  # from the installed unit; sets INST_*
  INST_HOME="$(unit_home)"; INST_USER="$(unit_value User)"; INST_GROUP="$(unit_value Group)"
  INST_RELEASE=""; INST_COMMIT=""; INST_ACTIVE="no"
  valid_home "$INST_HOME" || { log "installed unit: unusable ORACLE_OPS_HOME '$INST_HOME'"; INST_HOME=""; return 0; }
  INST_RELEASE="$(current_release "$INST_HOME")"
  [ -z "$INST_RELEASE" ] || INST_COMMIT="$(jar_commit "$INST_HOME" "$INST_RELEASE")"
  if service_active; then INST_ACTIVE="yes"; fi
  log "installed: home=$INST_HOME user=$INST_USER group=$INST_GROUP release=${INST_RELEASE:-none} commit=${INST_COMMIT:-unknown} active=$INST_ACTIVE"
}

pinned_release_running() {
  [ "$INST_RELEASE" = "$OPS_VERSION" ] && commit_matches_pin "$INST_COMMIT" && [ "$INST_ACTIVE" = yes ]
}

# The installation the unit points to must exist; Update credentials, Upgrade and De-install act on it.
require_installation() {
  if [ ! -f "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then finish 6 "Oracle OPS is not installed on this host"; fi
  describe_installation
  [ -n "$INST_HOME" ] || finish 1 "the installed $UNIT_NAME does not name a usable installation directory"
  if [ -L "$INST_HOME" ] || [ ! -d "$INST_HOME/releases" ]; then
    finish 6 "the Oracle OPS service definition points to $INST_HOME, which is not an Oracle OPS installation directory"
  fi
  valid_account_name "$INST_USER" && valid_account_name "$INST_GROUP" || finish 1 "the installed $UNIT_NAME does not name a usable service account"
}

home_state() {  # new | partial | foreign | symlink
  local h="$1" e found="" stray=""
  if [ -L "$h" ]; then echo symlink; return 0; fi
  if [ ! -e "$h" ]; then echo new; return 0; fi
  if [ ! -d "$h" ]; then echo foreign; return 0; fi
  while IFS= read -r e; do
    case "$e" in releases|config|logs|evidence|runtime|current) found=1 ;; *) stray=1 ;; esac
  done < <(find "$h" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
  if [ -n "$stray" ]; then echo foreign; elif [ -n "$found" ]; then echo partial; else echo new; fi
}

ask_home() {
  local h attempt
  for attempt in 1 2 3; do
    printf '      Installation directory [%s]: ' "$DEFAULT_HOME"
    read_line h || { echo; finish 5 "no installation directory was entered"; }
    h="${h:-$DEFAULT_HOME}"
    [ "$h" = "/" ] || h="${h%/}"
    if valid_home "$h"; then TARGET_HOME="$h"; log "installation directory: $h"; return 0; fi
    say "      Not usable: use an absolute path of letters, digits, '.', '_', '-' and '/', outside system directories."
  done
  finish 2 "no usable installation directory after three attempts"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Source: token, access check, download, verification, token destruction
# ---------------------------------------------------------------------------------------------------------------------------

read_token() {
  local t attempt
  say "      Oracle OPS is downloaded from its private GitHub repository. Enter a GitHub access token"
  say "      with read-only access to that repository. The token is not shown, stored or logged."
  for attempt in 1 2 3; do
    printf '      Access token: '
    IFS= read -r -s t || { echo; t=""; finish 5 "no access token was entered"; }
    echo
    t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"   # a pasted token may carry a newline or spaces
    if [[ "$t" =~ ^[A-Za-z0-9_]{20,255}$ ]]; then TOKEN="$t"; t=""; return 0; fi
    t=""
    say "      That is not a GitHub access token. Try again."
  done
  finish 4 "no valid access token was entered"
}

# The token file lives in a root-only directory on RAM-backed /run when that is safe, else in the run directory. The askpass
# helper holds no secret: it answers git's two prompts for the expected host only and refuses every other prompt.
make_auth() {
  if is_tmpfs "$AUTH_BASE" && ensure_private_dir_parent_ok "$AUTH_BASE"; then
    AUTH_DIR="$(mktemp -d "$AUTH_BASE/oracle-ops-installer.XXXXXXXX")" || finish 1 "cannot create a temporary directory in $AUTH_BASE"
  else
    AUTH_DIR="$RUN_DIR/auth"
    mkdir -m 0700 "$AUTH_DIR" || finish 1 "cannot create a temporary directory in $RUN_DIR"
  fi
  [[ "$AUTH_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] || finish 1 "internal error: unexpected temporary directory name"
  printf '%s %s\n' "$MARKER_TEXT" "$BASHPID" > "$AUTH_DIR/$MARKER_NAME"
  ( umask 077; printf '%s\n' "$TOKEN" > "$AUTH_DIR/token" ) || finish 1 "cannot write the temporary token file"
  cat > "$AUTH_DIR/askpass" <<EOF
#!/bin/sh
# Oracle OPS Installer: answers git's credential prompts for ${GIT_HOST_URL} only. It holds no secret.
case "\$1" in
  "Username for '${GIT_HOST_URL}'"*) printf '%s\n' '${GIT_USERNAME}' ;;
  "Password for '${GIT_PASSWORD_URL}'"*) exec cat -- '${AUTH_DIR}/token' ;;
  *) exit 1 ;;
esac
EOF
  chmod 0700 "$AUTH_DIR/askpass"
  log "temporary credential helper created in $AUTH_DIR (token file mode 0600)"
}

# /run must be owned by root and not writable by group/other for the token directory to go there.
ensure_private_dir_parent_ok() {
  local mode
  [ -d "$1" ] && [ ! -L "$1" ] && [ "$(stat -c %u "$1")" = "$ADMIN_UID" ] || return 1
  mode="$(stat -c %a "$1")"
  [ $((8#$mode & 8#022)) -eq 0 ]
}

classify_git_failure() {  # classify_git_failure <exit status>: a short, secret-free reason from the captured output
  local rc="$1"
  if [ "$rc" = 124 ]; then echo "the connection to GitHub timed out"; return 0; fi
  if grep -qiE 'Authentication failed|Invalid username or password|HTTP Basic: Access denied|returned error: 40[13]' "$CAPTURE" 2>/dev/null; then
    echo "GitHub rejected the access token"; return 0
  fi
  if grep -qiE 'Repository not found|repository .* not found|returned error: 404' "$CAPTURE" 2>/dev/null; then
    echo "the access token has no access to the Oracle OPS repository"; return 0
  fi
  if grep -qiE 'Could not resolve|Couldn.t resolve|Failed to connect|Connection (timed out|refused|reset)|Network is unreachable|SSL|TLS|early EOF|RPC failed|unable to access' "$CAPTURE" 2>/dev/null; then
    echo "GitHub could not be reached over HTTPS, or the download was interrupted"; return 0
  fi
  echo "the Oracle OPS source could not be downloaded"
}

verify_source() {
  local head dirty v f platforms
  run_quiet "check that the pinned commit is present" git_local cat-file -e "$OPS_COMMIT^{commit}" \
    || finish 4 "the pinned Oracle OPS release ${OPS_COMMIT:0:12} is not available in the repository"
  run_quiet "check out the pinned commit" git_local -c advice.detachedHead=false checkout --quiet --detach "$OPS_COMMIT" \
    || finish 4 "the pinned Oracle OPS release could not be checked out"
  head="$(git_local rev-parse HEAD 2>/dev/null)" || head=""
  [ "$head" = "$OPS_COMMIT" ] || finish 4 "the downloaded source is not the pinned commit"
  dirty="$(git_local status --porcelain 2>/dev/null | head -n 1)" || dirty="unknown"
  [ -z "$dirty" ] || finish 4 "the downloaded source does not match the pinned commit exactly"
  for f in service/VERSION service/build.sh deploy/java-runtime.properties deploy/scripts/deploy-oracle-ops.sh \
           deploy/scripts/install-release.sh deploy/scripts/activate-release.sh deploy/scripts/service-identity.sh \
           deploy/scripts/manage-app-credentials.sh deploy/scripts/ownership-lib.sh deploy/scripts/provision-java.sh; do
    if [ ! -f "$OPS_SRC/$f" ] || [ -L "$OPS_SRC/$f" ]; then finish 4 "the downloaded release lacks $f (installer and release do not match)"; fi
  done
  v="$(head -n 1 "$OPS_SRC/service/VERSION")"
  [ "$v" = "$OPS_VERSION" ] || finish 4 "the downloaded release is version '$v', the installer expects $OPS_VERSION"
  platforms="$(sed -n 's/^jdk\.platforms=//p' "$OPS_SRC/deploy/java-runtime.properties" | head -n 1)"
  in_list "$(host_platform)" "$platforms" || finish 4 "this Oracle OPS release does not support $(host_platform) (it supports: ${platforms:-none})"
  log "source verified: HEAD=$head VERSION=$v jdk.platforms=$platforms"
}

# Stage "Configuring source": ask for the token, prove access, download, destroy the token, verify. The token and the helper
# are removed BEFORE any downloaded code runs, so nothing from the repository can read them.
get_source() {
  local rc=0 reason
  read_token
  make_auth
  say "      Checking repository access..."
  run_quiet "check repository access" git_net "$GIT_LS_REMOTE_TIMEOUT" ls-remote --heads "$OPS_REPO_URL" || rc=$?
  if [ "$rc" != 0 ]; then reason="$(classify_git_failure "$rc")"; destroy_auth; finish 4 "$reason"; fi
  say "      Downloading Oracle OPS $OPS_VERSION..."
  OPS_SRC="$RUN_DIR/src"
  run_quiet "download the Oracle OPS source" git_net "$GIT_CLONE_TIMEOUT" clone --quiet --no-checkout "$OPS_REPO_URL" "$OPS_SRC" || rc=$?
  if [ "$rc" != 0 ]; then
    reason="$(classify_git_failure "$rc")"
    destroy_auth
    if [ -e "$OPS_SRC" ]; then rm -rf --one-file-system -- "$OPS_SRC" && log "removed the incomplete download"; fi
    finish 4 "$reason"
  fi
  destroy_auth
  log "access token and credential helper removed"
  say "      Verifying the downloaded release..."
  verify_source
}

# ---------------------------------------------------------------------------------------------------------------------------
# Verification after an action (read-only; the Oracle OPS scripts have already run their own checks)
# ---------------------------------------------------------------------------------------------------------------------------

# verify_installed <home>: the unit points to <home>, `current` selects the pinned version, the deployed build carries the
# pinned commit, and the service is active.
verify_installed() {
  local h="$1" problems="" rel c v
  if [ ! -f "$UNIT_FILE" ] || [ "$(unit_home)" != "$h" ]; then problems="$problems; the service definition does not point to $h"; fi
  rel="$(current_release "$h")"
  [ "$rel" = "$OPS_VERSION" ] || problems="$problems; the active release is '${rel:-none}', expected $OPS_VERSION"
  v="$(head -n 1 "$h/releases/$OPS_VERSION/VERSION" 2>/dev/null)" || v=""
  [ "$v" = "$OPS_VERSION" ] || problems="$problems; releases/$OPS_VERSION/VERSION is '${v:-missing}'"
  c="$(jar_commit "$h" "$OPS_VERSION")"
  commit_matches_pin "$c" || problems="$problems; the deployed build is from commit '${c:-unknown}', expected ${OPS_COMMIT:0:7}"
  service_active || problems="$problems; $UNIT_NAME is not active"
  if [ -n "$problems" ]; then log "verification FAILED: ${problems#; }"; VERIFY_PROBLEMS="${problems#; }"; return 1; fi
  log "verification passed: home=$h release=$rel commit=$c active=yes"
}
VERIFY_PROBLEMS=""

log_size() { stat -c %s "$1/$SERVICE_LOG_REL" 2>/dev/null || echo 0; }

# db_healthy_since <home> <byte offset>: the service logged a HEALTHY database check after the offset (a rotated log —
# smaller than the offset — is read from its start).
db_healthy_since() {
  local f="$1/$SERVICE_LOG_REL" off="$2" size
  [ -f "$f" ] || return 1
  size="$(stat -c %s "$f")"
  [ "$size" -ge "$off" ] || off=0
  tail -c +"$((off + 1))" "$f" | grep -qF "$DB_HEALTHY_LINE"
}

# ---------------------------------------------------------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------------------------------------------------------

op_install() {
  local rc=0 state
  OPERATION="installation"; STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Configuring Oracle OPS..."
  if [ -e "$UNIT_FILE" ] || [ -L "$UNIT_FILE" ]; then
    describe_installation
    if [ -n "$INST_HOME" ] && pinned_release_running; then
      SUCCESS_TEXT="Oracle OPS $OPS_VERSION is already installed at $INST_HOME and running. Nothing was changed."
      finish 0
    fi
    finish 6 "Oracle OPS is already installed${INST_HOME:+ at $INST_HOME}${INST_RELEASE:+ (release $INST_RELEASE)}. Choose 'Upgrade Oracle OPS' to install release $OPS_VERSION, or 'De-install Oracle OPS' first"
  fi
  ask_home
  state="$(home_state "$TARGET_HOME")"
  log "installation directory state: $state"
  case "$state" in
    new) ;;
    partial)
      say "      $TARGET_HOME holds an incomplete Oracle OPS installation from an earlier run."
      confirm_yes "Complete that installation?" || finish 5 "the earlier installation was left as it is"
      ;;
    symlink) finish 6 "$TARGET_HOME is a symbolic link; choose the real directory" ;;
    *) finish 6 "$TARGET_HOME exists and is not an Oracle OPS installation directory; choose a new or empty directory" ;;
  esac
  stage 3 "Configuring source..."
  get_source
  stage 4 "Installing Oracle OPS..."
  say "      The Oracle OPS setup assistant now asks for the service account, the database connection"
  say "      and the optional features. Its messages are shown below and recorded in the log."
  say "------------------------------------------------------------------------------------------"
  run_interactive "deploy-oracle-ops.sh --home $TARGET_HOME" \
    ops_run deploy-oracle-ops.sh --home "$TARGET_HOME" ${JAVA_ARCHIVE:+--java-archive "$JAVA_ARCHIVE"} || rc=$?
  say "------------------------------------------------------------------------------------------"
  [ "$rc" = 0 ] || finish 1 "the Oracle OPS setup assistant did not complete (exit $rc)"
  stage 5 "Finalizing installation..."
  verify_installed "$TARGET_HOME" || finish 1 "the installation could not be verified: $VERIFY_PROBLEMS"
  SUCCESS_TEXT="Oracle OPS installation completed successfully.
Release $OPS_VERSION (commit ${OPS_COMMIT:0:7}) is running from $TARGET_HOME.
Oracle APEX is not part of this installer; install and configure it separately."
  finish 0
}

op_upgrade() {
  local rc=0 mode="install" c offset from
  OPERATION="upgrade"; STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Checking the current installation..."
  require_installation
  from="${INST_RELEASE:-none}"
  say "      Found Oracle OPS $from at $INST_HOME (service account $INST_USER:$INST_GROUP)."
  if [ "$INST_RELEASE" = "$OPS_VERSION" ] && commit_matches_pin "$INST_COMMIT"; then
    if [ "$INST_ACTIVE" = yes ]; then
      SUCCESS_TEXT="Oracle OPS $OPS_VERSION is already installed and running. Nothing was changed."
      finish 0
    fi
    finish 6 "release $OPS_VERSION is already the active release but $UNIT_NAME is not running; check it with 'systemctl status $UNIT_NAME'"
  fi
  if [ -e "$INST_HOME/releases/$OPS_VERSION" ] || [ -L "$INST_HOME/releases/$OPS_VERSION" ]; then
    c="$(jar_commit "$INST_HOME" "$OPS_VERSION")"
    if commit_matches_pin "$c" && [ "$INST_RELEASE" != "$OPS_VERSION" ]; then
      mode="activate"
      say "      Release $OPS_VERSION is already deployed but not active (an earlier upgrade did not finish)."
    else
      finish 6 "release $OPS_VERSION is already installed at $INST_HOME but was built from different source (commit ${c:-unknown}); the pinned release cannot replace it under the same version number, a new Oracle OPS version is required"
    fi
  fi
  if [ ! -f "$INST_HOME/config/application.yaml" ] || [ ! -f "$CRED_DIR/database.credentials" ]; then
    finish 6 "the existing installation has no $INST_HOME/config/application.yaml or $CRED_DIR/database.credentials; an upgrade needs both in place"
  fi
  stage 3 "Configuring source..."
  get_source
  if [ "$mode" = install ]; then
    say "      Checking the upgrade (no changes yet)..."
    run_quiet "install-release.sh --preflight" ops_run install-release.sh --preflight --home "$INST_HOME" \
      --user "$INST_USER" --group "$INST_GROUP" ${JAVA_ARCHIVE:+--java-archive "$JAVA_ARCHIVE"} "$OPS_SRC/service" \
      || finish 1 "the upgrade pre-check failed; nothing was changed"
  fi
  say "      Oracle OPS at $INST_HOME will be upgraded from $from to $OPS_VERSION."
  say "      Oracle OPS is stopped and restarted (EBS is not affected); release $from stays installed."
  confirm_yes "Upgrade now?" || finish 5 "the upgrade was not confirmed; nothing was changed"
  stage 4 "Upgrading Oracle OPS..."
  offset="$(log_size "$INST_HOME")"
  if [ "$mode" = install ]; then
    run_quiet "install-release.sh" ops_run install-release.sh --home "$INST_HOME" --user "$INST_USER" --group "$INST_GROUP" \
      ${JAVA_ARCHIVE:+--java-archive "$JAVA_ARCHIVE"} "$OPS_SRC/service" || rc=$?
  else
    run_quiet "activate-release.sh" ops_run activate-release.sh --home "$INST_HOME" --release "$OPS_VERSION" || rc=$?
  fi
  if [ "$rc" != 0 ]; then
    log "rollback, if needed: activate-release.sh --home $INST_HOME --release $from (Oracle OPS deploy/scripts)"
    finish 1 "the Oracle OPS upgrade script failed (exit $rc); release $from is still installed"
  fi
  stage 5 "Finalizing upgrade..."
  verify_installed "$INST_HOME" || finish 1 "the upgrade could not be verified: $VERIFY_PROBLEMS"
  db_healthy_since "$INST_HOME" "$offset" || finish 1 "Oracle OPS $OPS_VERSION started but did not report a healthy database connection"
  run_quiet "service-identity.sh check" ops_run service-identity.sh check --home "$INST_HOME" \
    || finish 1 "the service account check after the upgrade reported deviations"
  SUCCESS_TEXT="Oracle OPS upgrade completed successfully.
Release $OPS_VERSION (commit ${OPS_COMMIT:0:7}) is running from $INST_HOME; release $from is kept for rollback."
  finish 0
}

op_deinstall() {
  local h retired="" e before
  OPERATION="de-installation"; STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Checking the current installation..."
  if [ -f "$UNIT_FILE" ] && [ ! -L "$UNIT_FILE" ]; then
    describe_installation
    h="$INST_HOME"
    [ -n "$h" ] || finish 1 "the installed $UNIT_NAME does not name a usable installation directory"
  else
    say "      No Oracle OPS service is defined; enter the directory of the installation to remove."
    ask_home
    h="$TARGET_HOME"
  fi
  if [ -L "$h" ] || [ ! -d "$h/releases" ]; then finish 6 "no Oracle OPS installation was found at $h"; fi
  say "      Oracle OPS at $h will be stopped and disabled, its systemd unit and log-rotation file removed,"
  say "      and $h renamed to $h.retired-<time>. Nothing is deleted; $CRED_DIR and OS accounts are not changed."
  confirm_yes "De-install Oracle OPS now?" || finish 5 "the de-installation was not confirmed; nothing was changed"
  stage 3 "Configuring source..."
  get_source
  stage 4 "De-installing Oracle OPS..."
  before="$(find "$(dirname "$h")" -mindepth 1 -maxdepth 1 -name "$(basename "$h").retired-*" -printf '%f\n' 2>/dev/null | sort)"
  run_quiet "service-identity.sh retire (dry run)" ops_run service-identity.sh retire --home "$h" \
    || finish 1 "the de-installation check failed; nothing was changed"
  run_quiet "service-identity.sh retire --apply" ops_run service-identity.sh retire --home "$h" --apply \
    || finish 1 "the Oracle OPS de-installation script failed"
  stage 5 "Finalizing de-installation..."
  while IFS= read -r e; do
    printf '%s\n' "$before" | grep -qxF -- "$e" || retired="$(dirname "$h")/$e"
  done < <(find "$(dirname "$h")" -mindepth 1 -maxdepth 1 -name "$(basename "$h").retired-*" -printf '%f\n' 2>/dev/null | sort)
  [ ! -e "$h" ] && [ ! -L "$h" ] || finish 1 "$h still exists after the de-installation"
  [ -n "$retired" ] && [ -d "$retired" ] || finish 1 "the renamed installation directory could not be found"
  if [ -f "$UNIT_FILE" ] && [ "$(unit_home)" = "$h" ]; then finish 1 "the $UNIT_NAME service definition still points to $h"; fi
  if [ -n "$INST_HOME" ] && service_active; then finish 1 "$UNIT_NAME is still running"; fi
  log "de-installation verified: $h renamed to $retired"
  SUCCESS_TEXT="Oracle OPS de-installation completed successfully.
The former installation was renamed to $retired (nothing was deleted).
Credentials in $CRED_DIR and OS accounts were not changed."
  finish 0
}

db_password_guidance() {
  say "      Oracle OPS reads its database password from $CRED_DIR/database.credentials."
  say "      No Oracle OPS tool replaces that file. To change the password:"
  say "        1. Have the DBA change the password of the Oracle OPS runtime account."
  say "        2. As root, edit $CRED_DIR/database.credentials and set the new db.password value"
  say "           (Java properties format: write a backslash as \\\\ and a space as '\\ ')."
  say "           Keep the file owned by root, group = the service group, mode 0640."
  say "        3. Restart Oracle OPS:  systemctl restart $UNIT_NAME"
  say "        4. Check for \"$DB_HEALTHY_LINE\" in <installation directory>/$SERVICE_LOG_REL."
  say "      Never put the password on a command line."
}

op_credentials() {
  local c rc=0 f st
  OPERATION="credential update"
  echo
  say "  Which credential?"
  say "    1) WebLogic administration account (stored for Oracle OPS)"
  say "    2) Database password of the Oracle OPS runtime account"
  say "    3) Cancel"
  choose c "  Choose 1, 2 or 3: " 1 2 3
  case "$c" in
    3) finish 5 "no credential was changed" ;;
    2) echo; db_password_guidance; SUCCESS_TEXT="No changes were made."; finish 0 ;;
  esac
  STAGE_TOTAL=5
  stage 1 "Checking system prerequisites..."
  check_prerequisites
  stage 2 "Checking the current installation..."
  require_installation
  if [ ! -d "$CRED_DIR" ] || [ -L "$CRED_DIR" ]; then finish 6 "the Oracle OPS credential directory $CRED_DIR does not exist"; fi
  stage 3 "Configuring source..."
  get_source
  stage 4 "Updating the WebLogic credential..."
  say "      The Oracle OPS credential manager now asks for the WebLogic user name and password"
  say "      (input hidden). Its messages are shown below and recorded in the log."
  say "------------------------------------------------------------------------------------------"
  run_interactive "manage-app-credentials.sh" ops_run manage-app-credentials.sh || rc=$?
  say "------------------------------------------------------------------------------------------"
  case "$rc" in
    0) ;;
    3) finish 5 "the existing WebLogic credential was kept" ;;
    *) finish 1 "the Oracle OPS credential manager did not complete (exit $rc)" ;;
  esac
  stage 5 "Finalizing..."
  f="$CRED_DIR/apps.credentials"
  st="$(stat -c '%a %u %g %h' "$f" 2>/dev/null)" || st=""
  if [ -L "$f" ] || [ ! -f "$f" ] || [ "$st" != "400 $(getent passwd "$INST_USER" | cut -d: -f3) $(getent group "$INST_GROUP" | cut -d: -f3) 1" ]; then
    finish 1 "the stored WebLogic credential file does not have the expected owner and permissions"
  fi
  log "credential file verified: $f mode 0400 owner $INST_USER:$INST_GROUP (content not read)"
  SUCCESS_TEXT="WebLogic credential updated successfully. (Oracle OPS was not restarted.)"
  finish 0
}

# ---------------------------------------------------------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: sudo bash $0 [--java-archive FILE]
       bash $0 --help | --version

Interactive installer for Oracle OPS release $OPS_VERSION (Oracle Linux 7, x86_64). Choose one action from the menu:
install, update credentials, upgrade, de-install. Oracle APEX is not part of this installer.

  --java-archive FILE   a pre-staged copy of the Oracle JDK archive pinned by Oracle OPS, for hosts that cannot
                        reach download.oracle.com (passed to the Oracle OPS scripts, which verify its checksum)
  --help                this text
  --version             installer version and the pinned Oracle OPS release

Logs: $LOG_DIR (root only). See README.md.
EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --version) printf 'Oracle OPS Installer %s (Oracle OPS %s, commit %s)\n' "$INSTALLER_VERSION" "$OPS_VERSION" "$OPS_COMMIT"; exit 0 ;;
      --java-archive)
        [ $# -ge 2 ] || die_early "--java-archive needs a file" 2
        JAVA_ARCHIVE="$2"; shift 2 ;;
      --java-archive=*) JAVA_ARCHIVE="${1#--java-archive=}"; shift ;;
      *) usage >&2; die_early "unknown argument: $1" 2 ;;
    esac
  done
  if [ -n "$JAVA_ARCHIVE" ]; then
    [[ "$JAVA_ARCHIVE" =~ ^/[A-Za-z0-9._/+-]+$ ]] || die_early "--java-archive needs an absolute path of plain characters" 2
    if [ -L "$JAVA_ARCHIVE" ] || [ ! -f "$JAVA_ARCHIVE" ] || [ ! -r "$JAVA_ARCHIVE" ]; then die_early "--java-archive: not a readable regular file" 2; fi
  fi
}

menu() {
  local c
  echo
  say "Oracle OPS Installer"
  say "===================="
  say "Oracle OPS release $OPS_VERSION. Oracle APEX is not installed or configured by this installer."
  echo
  say "  1) Install Oracle OPS"
  say "  2) Update credentials"
  say "  3) Upgrade Oracle OPS"
  say "  4) De-install Oracle OPS"
  say "  5) Exit"
  echo
  choose c "Choose an option [1-5]: " 1 2 3 4 5
  log "menu choice: $c"
  echo
  case "$c" in
    1) op_install ;;
    2) op_credentials ;;
    3) op_upgrade ;;
    4) op_deinstall ;;
    5) finish 0 ;;
  esac
}

main() {
  set -euo pipefail
  set +x +v
  umask 077
  scrub_environment
  parse_args "$@"
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    die_early "bash 4.2 or later is required" 2
  fi
  is_root || die_early "run the installer as root, for example:  sudo bash $0" 2
  stdin_is_tty || die_early "the installer is interactive; run it from a terminal" 2
  local t missing=""
  for t in $BOOTSTRAP_TOOLS; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
  [ -z "$missing" ] || die_early "basic system tools are missing:$missing" 3
  ROOT_HOME="$(root_home)"; ROOT_HOME="${ROOT_HOME:-/root}"
  export HOME="$ROOT_HOME"
  init_logging
  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  init_state
  menu
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
