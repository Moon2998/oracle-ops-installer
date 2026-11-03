#!/bin/bash
# Oracle OPS Installer library: host locations, limits, run state, and the seams tests replace (docs/DEVELOPER.md)
# Sourced only by the integrity loader in oracle-ops-installer.sh (digest-verified). Function definitions and constant
# global assignments only: nothing here may run a command at load time. Functions are moved verbatim from the single-file
# installer 96c8b73 (tests/compare-command-sequences.sh proves it).

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
CHECK_LOG_KEEP=20                           # check logs (oracle-ops-check-*.log) kept by the menu start-up; the CLI path never prunes
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

# ---- Read-only checks (status / validate): their own settings, never read from the environment ----------------------------
DEFAULT_SOURCE_REPO="/u01/oracle_ops"       # the local Oracle OPS repository validate reads the pinned commit from
STATUS_LOG_TAIL=2000                        # lines of the service log status examines
CLI_MODE=""                                 # status | validate when the installer was started with that subcommand
CLI_HOME=""                                 # --home given on the command line
CLI_HOME_SET=0
CLI_SOURCE_REPO=""                          # --source-repo given on the command line
CLI_SOURCE_REPO_SET=0
SOURCE_REPO=""                              # the repository validate reads (CLI option, menu answer or the default)
# Credential files status examines by metadata only (never opened): name:owner-kind:mode, owner-kind root = root:<Group>, service = <User>:<Group>.
CRED_FILES="database.credentials:root:640 api.credentials:root:640 api-control.credentials:root:640 apps.credentials:service:400"
# Tools a check needs besides the start-up tools; a missing one makes the items that need it FAIL (they are never skipped).
CHECK_BOOTSTRAP_TOOLS="id mkdir stat date flock sed tr dirname basename"

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

# service_state: the unit's state, from systemctl is-active and systemctl show (read-only verbs). Prints
#   IS_ACTIVE=<is-active answer>   (empty if systemctl printed none)
# followed by the four properties of show; fails when show fails. A status check uses nothing else of systemctl.
service_state() {
  local act=""
  if act="$(systemctl is-active "$UNIT_NAME" 2>/dev/null)"; then :; fi   # an inactive unit makes is-active exit non-zero
  printf 'IS_ACTIVE=%s\n' "$act"
  systemctl show -p ActiveState -p SubState -p MainPID -p ActiveEnterTimestamp "$UNIT_NAME" 2>/dev/null
}

# proc_owner_exe <pid>: who runs the process and which program, read from /proc (a /proc entry is owned by the process's
# user and group; the exe link names the program). Prints OWNER=<user>:<group> and EXE=<path>; fails if either is unreadable.
proc_owner_exe() {
  local o e
  o="$(stat -c '%U:%G' "/proc/$1" 2>/dev/null)" || return 1
  e="$(readlink "/proc/$1/exe" 2>/dev/null)" || return 1
  printf 'OWNER=%s\nEXE=%s\n' "$o" "$e"
}

# run_as_repo_owner <repository> <command...>: runs a command with the privileges of the account that owns <repository>/.git
# (its uid and that account's passwd primary group, no supplementary groups), in "/", in a scrubbed environment with
# HOME=/nonexistent, GIT_CONFIG_NOSYSTEM=1 and GIT_NO_REPLACE_OBJECTS=1, so that a repository somebody else can write is never
# read with root's privileges. Only when the owner is the administrative account (root) is the command run directly (still
# in "/" and in the same environment). Fails if the owner or its primary group cannot be determined.
run_as_repo_owner() {
  local repo="$1" uid gid="" pre=()
  shift
  uid="$(stat -c %u "$repo/.git" 2>/dev/null)" || return 1
  [[ "$uid" =~ ^[0-9]+$ ]] || return 1
  if [ "$uid" != "$ADMIN_UID" ]; then
    gid="$(getent passwd "$uid" 2>/dev/null | cut -d: -f4)" || return 1
    [[ "$gid" =~ ^[0-9]+$ ]] || return 1
    pre=(setpriv --reuid "$uid" --regid "$gid" --clear-groups)
  fi
  ( cd / || exit 1
    CHILD_HOME=/nonexistent
    export GIT_CONFIG_NOSYSTEM=1 GIT_NO_REPLACE_OBJECTS=1
    ENV_KEEP="$ENV_KEEP GIT_CONFIG_NOSYSTEM GIT_NO_REPLACE_OBJECTS"
    clean_env_exec ${pre[@]+"${pre[@]}"} "$@" )
}
