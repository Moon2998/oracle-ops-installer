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
# Read-only checks (menu 5 Status, 6 Validate; or from the command line, root, no terminal, nothing is changed):
#   Status                 examines the installed Oracle OPS (unit, release, build commit, runtime, service, log, file metadata)
#   Validate               status, then deploy/scripts/config-migrate.sh validate and service-identity.sh check, run from a
#                          verified copy of exactly six files taken from the local Oracle OPS repository (git archive of the
#                          pinned commit; each file's SHA-256 must equal OPS_FILE_MANIFEST below)
#
# Usage:   sudo bash oracle-ops-installer.sh [--java-archive FILE]
#          sudo bash oracle-ops-installer.sh status   [--home DIR]
#          sudo bash oracle-ops-installer.sh validate [--home DIR] [--source-repo DIR]
#          bash oracle-ops-installer.sh --help | --version
#
# Exit status: 0 done, or nothing to do, or no problem found | 1 the action failed, or a check failed | 2 cannot run as
#              invoked | 3 prerequisites missing | 4 source access or verification failed (also: validate cannot verify the
#              pinned source) | 5 cancelled by the operator | 6 the action does not apply to this host (nothing changed; for
#              status/validate: Oracle OPS is not installed) | 129/130/143 interrupted
#
# Layout: this entry script holds the version, the pinned Oracle OPS release, the library manifest, the loader and main().
# Everything else lives in lib/*.sh, which the loader verifies (SHA-256 per file; ownership of the whole path when run as
# root) before it sources anything: see "Library loader" below and docs/DEVELOPER.md. This file is also sourced by the test
# suite (tests/); everything runs from main(). Functions marked "seam" (lib/env.sh) wrap host-specific actions so tests can
# replace them, and the "Host locations" globals (lib/env.sh) are reassigned by the tests after sourcing (they are NOT read
# from the environment).

set +x +v   # never trace: a trace would print the access token the moment it is handled

INSTALLER_VERSION="0.2.0"

# ---- Pinned Oracle OPS release. Changed only by a reviewed installer release (docs/DEVELOPER.md). ----------------------
OPS_REPO_URL="https://github.com/Moon2998/oracle-ops.git"
OPS_COMMIT="63fb7c162c6b7076129b8a1f02b7bdb9b2dd44f5"   # full commit id; nothing else is ever checked out
OPS_VERSION="0.1.9"                                      # service/VERSION at OPS_COMMIT
SUPPORTED_PLATFORMS="ol:7"                               # /etc/os-release ID:major; must be in the release's jdk.platforms
SUPPORTED_ARCH="x86_64"
# git's credential prompts for OPS_REPO_URL, answered by the temporary askpass helper (and nothing else is answered).
GIT_HOST_URL="https://github.com"
GIT_USERNAME="x-access-token"
GIT_PASSWORD_URL="https://x-access-token@github.com"

# ---- Oracle OPS file manifest (R1): the trust anchor of "validate" ---------------------------------------------------------
# SHA-256 and path of every file validate takes out of the local Oracle OPS repository (git archive of OPS_COMMIT) and then runs
# or reads: exactly these six files, nothing else is extracted. They are the blobs at OPS_COMMIT. Changed together with the pin by
# a reviewed installer release (docs/DEVELOPER.md, "Moving the pin"): the digest is `git show <commit>:<path> | sha256sum`.
OPS_FILE_MANIFEST=(
  "4205c252ec5fca4aa289d6cf72374a321510cefbbb14a9b266f92b02ce413ed9  deploy/scripts/config-migrate.sh"
  "adb79693c16154bcb40126f91869540545e9453995b58375b60889633c35ae4e  deploy/scripts/service-identity.sh"
  "956121fda5804cc2ad1d54464103acd980ce7318401b279a3789815640911517  deploy/scripts/ownership-lib.sh"
  "2c1009dcfcef35d51e4a574b40d31441fe823bfe1ef8337e29f17bb4de674d85  deploy/scripts/provision-java.sh"
  "fa5e69025690abaa746781dbb858a488842cc37fc54e970de786a0f0f2678c23  deploy/java-runtime.properties"
  "e358d84552808a5c0bd6679d690c283b938ebe15c2bd843c898681d093213107  service/VERSION"
)

# ---- Library manifest: SHA-256 of every library the loader will source, in loading order. -----------------------------
# Regenerated by tests/update-lib-digests.sh (tests/run-tests.sh fails while it is stale); never edit a digest by hand.
# BEGIN LIB MANIFEST
LIB_MANIFEST=(
  "7ccb59b6ae61d4a27bfd6e42c3603127931bd015883a7fa4fc06e561a1f3bbf9  lib/env.sh"
  "5a68e83fd398046d811e493420e1c96a521d5e09fd107c2d56f6ddaec3ff9ee9  lib/common.sh"
  "7d16efd143248f07ff29a3e233afde2d6138a8e4f0962e69430d99a6a3775d5a  lib/state.sh"
  "de04dda6015382dac203843bb3d42022e8953500362963160b7eefdc8e516291  lib/prereq.sh"
  "cd13c3ceaf025e7b588db06cfc49c09c2387856252830575a17465cd61fb1f4d  lib/installation.sh"
  "a4b6b957711f0dc58f120864638d71e09c2b454eaf19ed54ad1d78d8e48ec941  lib/source.sh"
  "f47a00d1cc99e084b291ebf84629d2c76a3f3a8cb45eb80417bccec2d3e8f647  lib/ops-install.sh"
  "f9d672108166958b5dbb7dab4d03adc3c0a952adeb0818bfc62d0fd470d39e71  lib/ops-upgrade.sh"
  "fd17695ed722df47dc555a5123725c3ead4eacd7d6a40691ebab5d3bb8dbc1c5  lib/ops-deinstall.sh"
  "0b76b8e427643dc63e031f0fc75e25f4836ae70f3381617d844635828010e1b5  lib/ops-credentials.sh"
  "45ee4226ce47482e088bcb07b9f76ddfc9049cecebe88aebd8d1c313000d06a5  lib/check-startup.sh"
  "9c929e38522221cad99c24727e53de351fe5ea1b30dc165c7b174fae2f8f07dd  lib/ops-status.sh"
  "1a09e62a09f12ad8a51db286f622886cd5d14f544f4f0926c16642e33fab4861  lib/ops-validate.sh"
  "d9b96ade7cf46e92d61266aac72376191cacbccccb788a3f5585450f5d11ff34  lib/menu.sh"
)
# END LIB MANIFEST

# ---- Library loader ---------------------------------------------------------------------------------------------------------
# Runs before any library exists, so it uses only constants defined in this file and absolute tool paths (never PATH).
#  * Executed as root: the whole path (this file, lib/, every listed library, every directory up to /) must be owned by
#    uid 0 and not writable by group or other (a sticky directory is accepted only when the next path component is root-owned)
#    BEFORE anything is hashed. Executed as another user the ownership step is skipped (that user cannot gain privileges, and
#    the installer refuses to act unless root), so --help and --version work from a checkout.
#  * Every listed library must exist, be a regular file (not a symbolic link) and match its digest; only then is any of them
#    sourced. Files in lib/ that are not listed are never sourced.
#  * Sourced (the test suite): the libraries are verified and sourced at load; main() then runs the ownership check against
#    ADMIN_UID (see ldr_check_sourced_install).
# Any failure prints a message on stderr and returns 2 (sourced) or exits 2 (executed); no library code has run.
LOADER_ADMIN_UID=0
# Test seam: an owner accepted besides root by the ownership check. Always empty in a real run (reset here, so the environment
# cannot preset it); tests/lib.sh and the integrity tests set it after sourcing, in a subshell.
LOADER_TEST_UID=""
LOADER_EXECUTED=0
LOADER_ENTRY_FILE=""
LOADER_ENTRY_DIR=""
LOADER_STAT=""
LOADER_READLINK=""
LOADER_SHA256=""

ldr_fail() { printf 'Oracle OPS Installer: %s\n' "$1" >&2; }

# ldr_find_tool <variable> <tool>: absolute path of a system tool (/usr/bin, then /bin); false if there is none.
ldr_find_tool() {
  local _ld_d
  for _ld_d in /usr/bin /bin; do
    if [ -f "$_ld_d/$2" ] && [ -x "$_ld_d/$2" ]; then printf -v "$1" '%s' "$_ld_d/$2"; return 0; fi
  done
  return 1
}

# ldr_stat <path>: sets LDR_UID and LDR_MODE (octal permission bits, special bits included) of the path itself (a link is
# not followed); false if it cannot be examined.
ldr_stat() {
  local _ld_out
  _ld_out="$("$LOADER_STAT" -c '%u %a' -- "$1" 2>/dev/null)" || return 1
  LDR_UID="${_ld_out% *}"; LDR_MODE="${_ld_out#* }"
  [[ "$LDR_UID" =~ ^[0-9]+$ ]] && [[ "$LDR_MODE" =~ ^[0-7]{3,4}$ ]]
}

# ldr_owner_ok <uid> <extra uid or empty>: the owner is the loader's administrative account (root), or the extra account.
ldr_owner_ok() { [ "$1" = "$LOADER_ADMIN_UID" ] || { [ -n "$2" ] && [ "$1" = "$2" ]; }; }

# ldr_check_node <path> <extra uid> <next component or empty>: owned by root (or the extra account) and not writable by group
# or other. A sticky directory that is writable is accepted only when <next component> is owned like that too.
ldr_check_node() {
  local _ld_p="$1" _ld_x="$2" _ld_next="$3" _ld_m
  ldr_stat "$_ld_p" || { ldr_fail "cannot examine $_ld_p"; return 1; }
  ldr_owner_ok "$LDR_UID" "$_ld_x" || { ldr_fail "$_ld_p is not owned by an administrative account (owner uid $LDR_UID)"; return 1; }
  _ld_m=$((8#$LDR_MODE))
  [ $((_ld_m & 8#022)) -ne 0 ] || return 0
  if [ -d "$_ld_p" ] && [ ! -L "$_ld_p" ] && [ $((_ld_m & 8#1000)) -ne 0 ] && [ -n "$_ld_next" ]; then
    ldr_stat "$_ld_next" || { ldr_fail "cannot examine $_ld_next"; return 1; }
    if ldr_owner_ok "$LDR_UID" "$_ld_x"; then return 0; fi
    ldr_fail "$_ld_p is a sticky directory writable by other users and its next path component $_ld_next is not owned by an administrative account (owner uid $LDR_UID)"
    return 1
  fi
  ldr_fail "$_ld_p is writable by group or other users (mode $LDR_MODE)"
  return 1
}

# ldr_check_secure <real entry directory> <entry file> <extra owner uid or empty>: the secure-path check described above,
# outermost directory first. Each listed library is examined; a library that is missing is reported by the digest step.
ldr_check_secure() {
  local _ld_dir="$1" _ld_entry="$2" _ld_x="$3" _ld_chain=() _ld_p _ld_i _ld_next _ld_item _ld_rel
  [ ! -L "$_ld_entry" ] || { ldr_fail "$_ld_entry is a symbolic link"; return 1; }
  _ld_p="$_ld_dir"
  while :; do
    _ld_chain+=("$_ld_p")
    [ "$_ld_p" != "/" ] || break
    _ld_p="${_ld_p%/*}"; _ld_p="${_ld_p:-/}"
  done
  for (( _ld_i=${#_ld_chain[@]} - 1; _ld_i >= 0; _ld_i-- )); do
    if [ "$_ld_i" -gt 0 ]; then _ld_next="${_ld_chain[$((_ld_i - 1))]}"; else _ld_next="$_ld_entry"; fi
    ldr_check_node "${_ld_chain[$_ld_i]}" "$_ld_x" "$_ld_next" || return 1
  done
  ldr_check_node "$_ld_entry" "$_ld_x" "" || return 1
  [ ! -L "$_ld_dir/lib" ] || { ldr_fail "$_ld_dir/lib is a symbolic link"; return 1; }
  ldr_check_node "$_ld_dir/lib" "$_ld_x" "" || return 1
  for _ld_item in "${LIB_MANIFEST[@]}"; do
    _ld_rel="${_ld_item#*  }"
    [ ! -L "$_ld_dir/$_ld_rel" ] || { ldr_fail "$_ld_dir/$_ld_rel is a symbolic link"; return 1; }
    [ -e "$_ld_dir/$_ld_rel" ] || continue
    ldr_check_node "$_ld_dir/$_ld_rel" "$_ld_x" "" || return 1
  done
}

# ldr_run <entry script path> <1 if executed, 0 if sourced> <effective uid>: the whole loader; returns 2 on any failure.
ldr_run() {
  local _ld_src="$1" _ld_exec="$2" _ld_euid="$3" _ld_dir _ld_item _ld_digest _ld_rel _ld_file _ld_got _ld_files=()
  if [ -z "$_ld_src" ]; then
    ldr_fail "cannot locate the installer's own files: the script name is empty (run it from a file, not from standard input)"
    return 2
  fi
  ldr_find_tool LOADER_STAT stat && ldr_find_tool LOADER_READLINK readlink && ldr_find_tool LOADER_SHA256 sha256sum \
    || { ldr_fail "stat, readlink and sha256sum are required in /usr/bin or /bin"; return 2; }
  _ld_dir="${_ld_src%/*}"
  if [ "$_ld_dir" = "$_ld_src" ]; then _ld_dir="."; else _ld_dir="${_ld_dir:-/}"; fi
  _ld_dir="$("$LOADER_READLINK" -f -- "$_ld_dir" 2>/dev/null)" && [ -d "$_ld_dir" ] \
    || { ldr_fail "cannot resolve the directory of $_ld_src"; return 2; }
  LOADER_EXECUTED="$_ld_exec"
  LOADER_ENTRY_DIR="$_ld_dir"
  LOADER_ENTRY_FILE="$_ld_dir/${_ld_src##*/}"
  if [ "$_ld_exec" = 1 ] && [ "$_ld_euid" = "$LOADER_ADMIN_UID" ]; then
    ldr_check_secure "$LOADER_ENTRY_DIR" "$LOADER_ENTRY_FILE" "$LOADER_TEST_UID" || return 2
  fi
  [ "${#LIB_MANIFEST[@]}" -gt 0 ] || { ldr_fail "the library manifest is empty"; return 2; }
  for _ld_item in "${LIB_MANIFEST[@]}"; do
    _ld_digest="${_ld_item%%  *}"; _ld_rel="${_ld_item#*  }"
    if [[ ! "$_ld_digest" =~ ^[0-9a-f]{64}$ ]] || [[ ! "$_ld_rel" =~ ^lib/[a-z0-9-]+\.sh$ ]]; then
      ldr_fail "the library manifest is malformed: $_ld_item"; return 2
    fi
    _ld_file="$_ld_dir/$_ld_rel"
    if [ -L "$_ld_file" ]; then ldr_fail "$_ld_rel is a symbolic link"; return 2; fi
    if [ ! -f "$_ld_file" ]; then ldr_fail "$_ld_rel is missing or not a regular file"; return 2; fi
    _ld_got="$("$LOADER_SHA256" -- "$_ld_file" 2>/dev/null)" || { ldr_fail "cannot read $_ld_rel"; return 2; }
    _ld_got="${_ld_got%% *}"
    if [ "$_ld_got" != "$_ld_digest" ]; then ldr_fail "$_ld_rel does not match its recorded SHA-256 digest"; return 2; fi
    _ld_files+=("$_ld_file")
  done
  for _ld_file in "${_ld_files[@]}"; do
    # shellcheck source=/dev/null
    . "$_ld_file"
  done
}

# Sourced only (the test suite): main() calls this first; the same ownership check as for a root run, against ADMIN_UID
# (after the tests reassign it). An executed run was checked (root) or deliberately not (other users) by the loader.
ldr_check_sourced_install() {
  [ "$LOADER_EXECUTED" != 1 ] || return 0
  ldr_check_secure "$LOADER_ENTRY_DIR" "$LOADER_ENTRY_FILE" "${LOADER_TEST_UID:-$ADMIN_UID}" || exit 2
}

# ---------------------------------------------------------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------------------------------------------------------

main() {
  ldr_check_sourced_install
  set -euo pipefail
  set +x +v
  umask 077
  scrub_environment
  parse_args "$@"
  if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    die_early "bash 4.2 or later is required" 2
  fi
  is_root || die_early "run the installer as root, for example:  sudo bash $0" 2
  [ -z "$CLI_MODE" ] || check_main "$CLI_MODE"   # status / validate: the strict read-only path; never returns
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
  prune_check_logs
  menu
}

[ "${BASH_SOURCE[0]:-}" != "$0" ] || LOADER_EXECUTED=1
ldr_run "${BASH_SOURCE[0]:-}" "$LOADER_EXECUTED" "$EUID" || { return 2 2>/dev/null || exit 2; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
