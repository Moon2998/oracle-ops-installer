#!/bin/bash
# Hermetic tests for oracle-ops-installer.sh. Run: tests/run-tests.sh (or this file directly).
# The numbers in brackets are the scenarios of the installer requirements (docs/DEVELOPER.md, "Test coverage").

set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOME_DIR() { printf '%s' "$SB/u01/oracle_ops_runtime"; }

# ---- invocation ----------------------------------------------------------------------------------------------------------

test_help_version_and_bad_argument() {
  run_installer --help;    assert_rc 0; assert_out "Usage:"; assert_out "Oracle APEX is not part of this installer"
  run_installer --version; assert_rc 0; assert_out "$FIX_COMMIT"
  run_installer --bogus;   assert_rc 2; assert_out "unknown argument"
  run_installer --java-archive relative/jdk.tar.gz; assert_rc 2
  assert_absent "$SB/var/log/oracle-ops-installer"
}

test_requires_root() {
  EXTRA='is_root() { return 1; }'
  run_installer
  assert_rc 2; assert_out "run the installer as root"
  assert_absent "$SB/var/log/oracle-ops-installer"; assert_absent "$SB/var/lib/oracle-ops-installer"
}

test_requires_terminal() {
  EXTRA='stdin_is_tty() { return 1; }'
  run_installer
  assert_rc 2; assert_out "run it from a terminal"
}

test_exit_option_changes_nothing() {
  input 5
  run_installer
  assert_rc 0; assert_out "1) Install Oracle OPS"; assert_out "5) Exit"
  assert_clean; assert_no_trace; assert_absent "$SB/git-trace"
}

test_end_of_input_at_menu_is_a_cancellation() {   # [22]
  run_installer
  assert_rc 5; assert_out "Cancelled"; assert_clean
}

test_invalid_menu_choice() {   # [13]
  input 9 x 0
  run_installer
  assert_rc 2; assert_out "Please enter one of"; assert_clean
}

# ---- install ---------------------------------------------------------------------------------------------------------------

test_install_success() {   # [1] [6] [14] [17] [19] [20] [24]
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 0
  assert_out "[1/5] Checking system prerequisites..."; assert_out "[2/5] Configuring Oracle OPS..."
  assert_out "[3/5] Configuring source..."; assert_out "[4/5] Installing Oracle OPS..."; assert_out "[5/5] Finalizing installation..."
  assert_out "Oracle OPS installation completed successfully."
  [ "$(readlink "$(HOME_DIR)/current")" = "$(HOME_DIR)/releases/$FIX_VERSION" ] || fail "current does not select $FIX_VERSION"
  # the pinned commit, not the newer tip of the default branch, was installed
  assert_trace "deploy-oracle-ops.sh args=--home $(HOME_DIR)"
  assert_trace "head=$FIX_COMMIT"
  # credential material was gone before any downloaded code ran
  assert_trace "deploy-oracle-ops.sh authdirs=0"; assert_trace "deploy-oracle-ops.sh tokenenv=0"; assert_trace "deploy-oracle-ops.sh tokenfiles=0"
  # the Oracle OPS script gets root's umask and no TMPDIR (its database check stages files in /tmp)
  assert_trace "umask=0022 tmpdir=unset lc_all=C"
  # no internal git operation or repository URL reaches the terminal
  assert_not_out "github.com"; assert_not_out "clone"; assert_not_out "git "
  assert_clean; assert_no_token; assert_log_protected
  assert_log "source verified: HEAD=$FIX_COMMIT"
}

test_install_runs_only_the_deploy_script_and_nothing_apex() {   # [24]
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 0
  local scripts
  scripts="$(sed -n 's/^\([^ ]*\) args=.*/\1/p' "$SB/roothome/trace" | sort -u | tr '\n' ' ')"
  [ "$scripts" = "deploy-oracle-ops.sh " ] || fail "unexpected Oracle OPS scripts were run: $scripts"
  # static: the installer never invokes anything APEX-related (APEX appears only in messages and comments)
  if grep -n -i 'apex' "$INSTALLER" | grep -v -E '^[0-9]+:[[:space:]]*#' | grep -v -i -E 'say |Oracle APEX is not|APEX-related|apex is out of scope' ; then
    fail "the installer has a non-message reference to APEX"
  fi
}

test_install_passes_java_archive() {
  : > "$SB/jdk-21.tar.gz"
  input 1 "" "$TEST_TOKEN" yes
  run_installer --java-archive "$SB/jdk-21.tar.gz"
  assert_rc 0
  assert_trace "deploy-oracle-ops.sh args=--home $(HOME_DIR) --java-archive $SB/jdk-21.tar.gz"
}

test_missing_prerequisite_manual() {   # [2] [4]
  rm -f "$SB/bin/git"
  input 1 2
  run_installer
  assert_rc 3
  assert_out "git (package git)"; assert_out "yum install -y git"
  assert_not_out "Access token"; assert_absent "$SB/git-trace"; assert_no_trace; assert_clean
}

test_missing_prerequisite_automatic() {   # [3]
  rm -f "$SB/bin/git" "$SB/bin/unzip"
  input 1 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 0
  grep -qF "yum -y install git unzip" "$SB/yum-trace" || fail "yum was not asked for exactly the missing packages"
  assert_out "Oracle OPS installation completed successfully."
}

test_prerequisite_installation_fails() {   # [5]
  rm -f "$SB/bin/git"
  echo fail > "$SB/yum-mode"
  input 1 1
  run_installer
  assert_rc 3; assert_out "Reason: the package manager could not install: git"; assert_no_trace; assert_clean
}

test_prerequisite_still_missing_after_installation() {   # [5]
  rm -f "$SB/bin/git"
  echo noop > "$SB/yum-mode"
  input 1 1
  run_installer
  assert_rc 3; assert_out "still missing"; assert_no_trace; assert_clean
}

test_unsupported_operating_system() {
  printf 'ID="ubuntu"\nVERSION_ID="22.04"\n' > "$SB/etc/os-release"
  input 1
  run_installer
  assert_rc 3; assert_out "operating system ubuntu:22 is not supported"; assert_clean
}

test_authentication_fails() {   # [7]
  printf 'ghp_WRONGtoken0123456789abcdefABCDEF0123\n' > "$SB/expected-token"
  input 1 "" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "Reason: GitHub rejected the access token."
  assert_out "Review the administrator installation log"
  assert_no_trace; assert_clean; assert_no_token
}

test_repository_access_denied() {   # [8]
  git_mode AUTH denied
  input 1 "" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "has no access to the Oracle OPS repository"; assert_no_trace; assert_clean; assert_no_token
}

test_network_failure() {
  git_mode AUTH network
  input 1 "" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "could not be reached"; assert_clean
}

test_invalid_token_format_is_rejected_before_use() {
  input 1 "" "not a token" "short" "ab'cd\"ef ghij klmn opqr"
  run_installer
  assert_rc 4; assert_out "That is not a GitHub access token"; assert_absent "$SB/git-trace"; assert_clean
}

test_pasted_token_with_surrounding_whitespace_is_accepted() {
  input 1 "" "   $TEST_TOKEN  " yes
  run_installer
  assert_rc 0; assert_no_token
}

test_pinned_reference_unavailable() {   # [9]
  EXTRA='OPS_COMMIT=1111111111111111111111111111111111111111'
  input 1 "" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "is not available in the repository"; assert_no_trace; assert_clean
}

test_release_version_mismatch() {
  EXTRA='OPS_VERSION=9.9.9'
  input 1 "" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_out "the installer expects 9.9.9"; assert_no_trace; assert_clean
}

test_partial_clone_is_removed() {   # [10]
  git_mode CLONE partial
  input 1 "" "$TEST_TOKEN"
  run_installer
  assert_rc 4; assert_log "removed the incomplete download"; assert_no_trace; assert_clean
}

test_leftover_staging_directory_of_an_interrupted_run() {   # [11]
  mkdir -p "$SB/var/lib/oracle-ops-installer/run.OLDRUN01/src"
  chmod 0700 "$SB/var/lib/oracle-ops-installer" "$SB/var/lib/oracle-ops-installer/run.OLDRUN01"
  echo "oracle-ops-installer-run 1 x" > "$SB/var/lib/oracle-ops-installer/run.OLDRUN01/.oracle-ops-installer-run"
  mkdir -m 0700 "$SB/run/oracle-ops-installer.OLDAUTH1"
  echo "oracle-ops-installer-run 1" > "$SB/run/oracle-ops-installer.OLDAUTH1/.oracle-ops-installer-run"
  echo stale > "$SB/run/oracle-ops-installer.OLDAUTH1/token"
  input 5
  run_installer
  assert_rc 0; assert_clean
  assert_log "earlier, interrupted run"
}

test_unrelated_data_in_staging_directory_stops_the_run() {   # [11]
  mkdir -m 0700 -p "$SB/var/lib/oracle-ops-installer"
  echo keep > "$SB/var/lib/oracle-ops-installer/notes.txt"
  mkdir "$SB/var/lib/oracle-ops-installer/run.FOREIGN1"
  input 5
  run_installer
  assert_rc 1; assert_out "not created by this installer"
  [ "$(cat "$SB/var/lib/oracle-ops-installer/notes.txt")" = keep ] || fail "unrelated file was changed"
  assert_exists "$SB/var/lib/oracle-ops-installer/run.FOREIGN1"
}

test_symlinked_or_foreign_owned_directories_are_refused() {   # [12]
  mkdir -p "$SB/elsewhere"
  ln -s "$SB/elsewhere" "$SB/var/lib/oracle-ops-installer"
  input 5
  run_installer
  assert_rc 1; assert_out "is a symbolic link"
  [ -z "$(ls -A "$SB/elsewhere")" ] || fail "something was written through the link"
  rm -f "$SB/var/lib/oracle-ops-installer"
  rm -rf "$SB/var/log/oracle-ops-installer"
  ln -s "$SB/elsewhere" "$SB/var/log/oracle-ops-installer"
  run_installer
  assert_rc 1; assert_out "cannot use the log directory"
  [ -z "$(ls -A "$SB/elsewhere")" ] || fail "a log was written through the link"
  rm -f "$SB/var/log/oracle-ops-installer"
  EXTRA='ADMIN_UID=99999'   # the parent directories are not owned by the expected administrative account
  run_installer
  assert_rc 1; assert_out "must be a real directory owned by root"
}

test_invalid_installation_directory() {   # [13]
  input 1 "relative/dir" "$SB/u01/../etc" "/etc/oracle-ops-x"
  run_installer
  assert_rc 2; assert_out "Not usable"; assert_absent "$SB/git-trace"; assert_clean
}

test_installation_directory_symlink_or_foreign() {   # [12] [21]
  mkdir -p "$SB/u01/real"; ln -s "$SB/u01/real" "$SB/u01/link"
  input 1 "$SB/u01/link"
  run_installer
  assert_rc 6; assert_out "is a symbolic link"
  mkdir -p "$SB/u01/data"; echo precious > "$SB/u01/data/file"
  input 1 "$SB/u01/data"
  run_installer
  assert_rc 6; assert_out "is not an Oracle OPS installation directory"
  [ "$(cat "$SB/u01/data/file")" = precious ] || fail "unrelated data was changed"
}

test_setup_assistant_fails() {   # [15] [18]
  stub_mode DEPLOY_MODE fail
  input 1 "" "$TEST_TOKEN"
  run_installer
  assert_rc 1; assert_out "Oracle OPS installation failed."; assert_out "the Oracle OPS setup assistant did not complete (exit 1)"
  assert_out "database validation failed"   # the assistant's own message was shown
  assert_log "database validation failed"   # and recorded
  assert_clean; assert_no_token
}

test_verification_failure_is_reported_and_runtime_kept() {   # [16] [21]
  stub_mode DEPLOY_MODE wrongcommit
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 1; assert_out "the installation could not be verified"; assert_out "commit 'deadbee'"
  assert_not_out "completed successfully"
  assert_exists "$(HOME_DIR)/releases/$FIX_VERSION/oracle-ops.jar"   # no invented rollback
  assert_clean
}

test_verification_failure_without_active_release() {   # [16]
  stub_mode DEPLOY_MODE nocurrent
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 1; assert_out "the active release is 'none'"; assert_clean
}

test_token_is_redacted_if_a_tool_prints_it() {   # [20]
  git_mode AUTH leak
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 0
  assert_log "[REDACTED]"; assert_no_token
}

test_token_without_a_known_prefix_is_redacted() {   # [20] a classic 40-hex token matches no GitHub token pattern
  TEST_TOKEN="0123456789abcdef0123456789abcdef01234567"
  printf '%s\n' "$TEST_TOKEN" > "$SB/expected-token"
  printf 'TEST_TOKEN=%s\n' "$TEST_TOKEN" >> "$SB/roothome/stub.conf"
  git_mode AUTH leak
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 0
  assert_log "[REDACTED]"; assert_no_token
}

test_git_runs_isolated_and_askpass_is_host_bound() {   # [19] [20]
  printf 'touch %q\n' "$SB/bash-env-ran" > "$SB/evil-bash-env.sh"
  EXTRA="export BASH_ENV=$SB/evil-bash-env.sh LEAKY_SENTINEL=1"
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 0
  assert_absent "$SB/bash-env-ran"
  grep -q "LEAKY_SENTINEL\|BASH_ENV" "$SB/git-trace" && fail "the caller's environment reached git"
  grep -q "LEAKY_SENTINEL\|BASH_ENV" "$SB/roothome/trace" && fail "the caller's environment reached an Oracle OPS script"
  grep -q "token-in-argv\|token-in-env" "$SB/git-trace" && fail "the token reached git's arguments or environment"
  grep -q "askpass-answered-foreign" "$SB/git-trace" && fail "the askpass helper answered a prompt for another host"
  grep -q "env HOME=$SB/var/lib/oracle-ops-installer/run\.[A-Za-z0-9]*/githome GIT_ASKPASS=.* GIT_CONFIG_NOSYSTEM=1" "$SB/git-trace" \
    || fail "git did not run with an empty HOME and without system configuration"
  grep -q "askpass-mode=700 token-mode=600" "$SB/git-trace" || fail "credential helper or token file permissions are wrong"
  grep -q "^envnames: .*BASH_ENV" "$SB/git-trace" && fail "BASH_ENV reached git"
  return 0
}

test_token_directory_on_tmpfs_is_used_and_removed() {   # [19]
  TEST_TMPFS=1
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 0
  grep -q "GIT_ASKPASS=$SB/run/oracle-ops-installer\.[A-Za-z0-9]*/askpass" "$SB/git-trace" || fail "the token directory was not placed in AUTH_BASE"
  assert_clean
}

test_existing_installation_is_never_overwritten_by_install() {   # [21]
  existing_install 0.1.4 abcdef1
  local before
  before="$(tree_digest "$(HOME_DIR)")"
  input 1
  run_installer
  assert_rc 6; assert_out "Oracle OPS is already installed"; assert_out "Choose 'Upgrade Oracle OPS'"
  [ "$(tree_digest "$(HOME_DIR)")" = "$before" ] || fail "the existing installation was changed"
  assert_absent "$SB/git-trace"; assert_clean
}

test_repeated_install_is_safe() {   # [23]
  input 1 "" "$TEST_TOKEN" yes
  run_installer
  assert_rc 0
  local before
  before="$(tree_digest "$(HOME_DIR)")"
  cp "$SB/git-trace" "$SB/git-trace.first"
  input 1
  run_installer
  assert_rc 0; assert_out "already installed at $(HOME_DIR) and running. Nothing was changed."
  cmp -s "$SB/git-trace" "$SB/git-trace.first" || fail "the second run contacted the repository"
  [ "$(tree_digest "$(HOME_DIR)")" = "$before" ] || fail "the second run changed the installation"
  assert_clean
}

test_incomplete_earlier_installation_needs_confirmation() {
  mkdir -p "$(HOME_DIR)/releases" "$(HOME_DIR)/logs"
  input 1 "" no
  run_installer
  assert_rc 5; assert_out "incomplete Oracle OPS installation"; assert_absent "$SB/git-trace"
  input 1 "" yes "$TEST_TOKEN" yes
  run_installer
  assert_rc 0; assert_out "completed successfully"
}

test_interrupt_during_installation_cleans_up() {   # [22]
  stub_mode DEPLOY_MODE selfkill
  input 1 "" "$TEST_TOKEN"
  run_installer
  assert_rc 143; assert_out "Oracle OPS installation was interrupted."; assert_clean; assert_no_token
}

# ---- upgrade -------------------------------------------------------------------------------------------------------------

test_upgrade_success() {
  existing_install 0.1.4 abcdef1
  input 3 "$TEST_TOKEN" yes
  run_installer
  assert_rc 0; assert_out "Oracle OPS upgrade completed successfully."; assert_out "release 0.1.4 is kept for rollback"
  assert_trace "install-release.sh args=--preflight --home $(HOME_DIR) --user $(id -un) --group $(id -gn)"
  assert_trace "install-release.sh args=--home $(HOME_DIR) --user $(id -un) --group $(id -gn)"
  assert_trace "service-identity.sh args=check --home $(HOME_DIR)"
  [ "$(readlink -f "$(HOME_DIR)/current")" = "$(HOME_DIR)/releases/$FIX_VERSION" ] || fail "current not switched"
  assert_exists "$(HOME_DIR)/releases/0.1.4/oracle-ops.jar"
  assert_trace "install-release.sh authdirs=0"; assert_clean; assert_no_token
}

test_upgrade_declined_changes_nothing() {   # [22]
  existing_install 0.1.4 abcdef1
  input 3 "$TEST_TOKEN" no
  run_installer
  assert_rc 5; assert_out "the upgrade was not confirmed"
  grep -q "^install-release.sh args=--home" "$SB/roothome/trace" && fail "the upgrade ran without confirmation"
  [ "$(readlink -f "$(HOME_DIR)/current")" = "$(HOME_DIR)/releases/0.1.4" ] || fail "current changed"
  assert_clean
}

test_upgrade_preflight_failure() {
  existing_install 0.1.4 abcdef1
  stub_mode PREFLIGHT_MODE fail
  input 3 "$TEST_TOKEN"
  run_installer
  assert_rc 1; assert_out "the upgrade pre-check failed"; assert_log "not enough free space"
  grep -q "^install-release.sh args=--home" "$SB/roothome/trace" && fail "installed after a failed pre-check"
  assert_clean
}

test_upgrade_script_failure() {
  existing_install 0.1.4 abcdef1
  stub_mode INSTALL_MODE fail
  input 3 "$TEST_TOKEN" yes
  run_installer
  assert_rc 1; assert_out "Oracle OPS upgrade failed."; assert_out "release 0.1.4 is still installed"
  assert_log "activate-release.sh --home $(HOME_DIR) --release 0.1.4"
  assert_clean
}

test_upgrade_unhealthy_database_is_a_failure() {   # [16]
  existing_install 0.1.4 abcdef1
  stub_mode INSTALL_MODE unhealthy
  input 3 "$TEST_TOKEN" yes
  run_installer
  assert_rc 1; assert_out "did not report a healthy database connection"; assert_clean
}

test_upgrade_identity_check_failure() {
  existing_install 0.1.4 abcdef1
  stub_mode CHECK_MODE fail
  input 3 "$TEST_TOKEN" yes
  run_installer
  assert_rc 1; assert_out "service account check"; assert_clean
}

test_upgrade_already_current() {
  existing_install "$FIX_VERSION" "${FIX_COMMIT:0:7}"
  input 3
  run_installer
  assert_rc 0; assert_out "already installed and running. Nothing was changed."; assert_absent "$SB/git-trace"
}

test_upgrade_same_version_from_other_source_is_refused() {
  existing_install "$FIX_VERSION" 3efda19
  input 3
  run_installer
  assert_rc 6; assert_out "built from different source (commit 3efda19)"; assert_absent "$SB/git-trace"; assert_clean
}

test_upgrade_needs_configuration_and_credentials() {
  existing_install 0.1.4 abcdef1
  rm -f "$SB/etc/oracle-ops/database.credentials"
  input 3
  run_installer
  assert_rc 6; assert_out "an upgrade needs both in place"; assert_absent "$SB/git-trace"
}

test_upgrade_resumes_a_deployed_but_inactive_release() {
  existing_install 0.1.4 abcdef1
  local h; h="$(HOME_DIR)"
  mkdir -p "$h/releases/$FIX_VERSION"; printf '%s\n' "$FIX_VERSION" > "$h/releases/$FIX_VERSION/VERSION"
  python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("com/oracleops/core/version.properties","build.gitCommit=%s\n"%sys.argv[2]); z.close()' \
    "$h/releases/$FIX_VERSION/oracle-ops.jar" "${FIX_COMMIT:0:7}"
  input 3 "$TEST_TOKEN" yes
  run_installer
  assert_rc 0; assert_out "already deployed but not active"
  assert_trace "activate-release.sh args=--home $h --release $FIX_VERSION"
  grep -q "^install-release.sh" "$SB/roothome/trace" && fail "install-release.sh was used for an already deployed release"
  return 0
}

test_upgrade_without_installation() {
  input 3
  run_installer
  assert_rc 6; assert_out "Oracle OPS is not installed on this host"
}

# ---- de-install -----------------------------------------------------------------------------------------------------------

test_deinstall_success_renames_and_keeps_credentials() {
  existing_install 0.1.4 abcdef1
  local cred_before
  cred_before="$(sha256sum "$SB/etc/oracle-ops/database.credentials")"
  input 4 yes "$TEST_TOKEN"
  run_installer
  assert_rc 0; assert_out "Oracle OPS de-installation completed successfully."
  assert_absent "$(HOME_DIR)"; assert_absent "$SB/etc/systemd/system/oracle-ops.service"
  ls -d "$(HOME_DIR)".retired-* >/dev/null 2>&1 || fail "the renamed installation is missing"
  assert_exists "$(ls -d "$(HOME_DIR)".retired-* | head -n 1)/releases/0.1.4/oracle-ops.jar"
  [ "$(sha256sum "$SB/etc/oracle-ops/database.credentials")" = "$cred_before" ] || fail "credentials changed"
  assert_trace "service-identity.sh args=retire --home $(HOME_DIR)"
  assert_trace "service-identity.sh args=retire --home $(HOME_DIR) --apply"
  assert_clean; assert_no_token
}

test_deinstall_declined() {
  existing_install 0.1.4 abcdef1
  input 4 no
  run_installer
  assert_rc 5; assert_exists "$(HOME_DIR)/current"; assert_absent "$SB/git-trace"; assert_clean
}

test_deinstall_without_installation() {
  input 4 "$SB/u01/nothing"
  run_installer
  assert_rc 6; assert_out "no Oracle OPS installation was found"
}

# ---- credentials ----------------------------------------------------------------------------------------------------------

test_update_weblogic_credential() {
  existing_install 0.1.4 abcdef1
  input 2 1 "$TEST_TOKEN" weblogic 'S3cret-Pass_word'
  run_installer
  assert_rc 0; assert_out "WebLogic credential updated successfully."
  [ "$(stat -c %a "$SB/etc/oracle-ops/apps.credentials")" = 400 ] || fail "apps.credentials mode"
  assert_trace "manage-app-credentials.sh args="
  assert_trace "manage-app-credentials.sh authdirs=0"
  grep -rqF 'S3cret-Pass_word' "$SB/var/log" "$SB/out" && fail "the WebLogic password appears in the output or the log"
  assert_clean; assert_no_token
}

test_update_weblogic_credential_declined() {
  existing_install 0.1.4 abcdef1
  stub_mode CRED_MODE decline
  input 2 1 "$TEST_TOKEN"
  run_installer
  assert_rc 5; assert_out "the existing WebLogic credential was kept"; assert_clean
}

test_update_weblogic_credential_wrong_permissions_detected() {
  existing_install 0.1.4 abcdef1
  stub_mode CRED_MODE badperm
  input 2 1 "$TEST_TOKEN" weblogic pw
  run_installer
  assert_rc 1; assert_out "does not have the expected owner and permissions"; assert_clean
}

test_database_password_guidance_changes_nothing() {
  input 2 2
  run_installer
  assert_rc 0; assert_out "database.credentials"; assert_out "No changes were made."
  assert_absent "$SB/git-trace"; assert_no_trace; assert_clean
}

# ---- locking and logs ------------------------------------------------------------------------------------------------------

test_concurrent_run_is_refused() {
  mkdir -m 0700 -p "$SB/var/lib/oracle-ops-installer"
  : > "$SB/var/lib/oracle-ops-installer/.lock"
  flock "$SB/var/lib/oracle-ops-installer/.lock" sleep 5 &
  local holder=$!
  sleep 0.5
  input 5
  run_installer
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  assert_rc 1; assert_out "another run of the Oracle OPS Installer is in progress"
}

test_log_rotation_keeps_the_newest_and_nothing_else_is_removed() {
  local d="$SB/var/log/oracle-ops-installer" i
  mkdir -m 0700 -p "$d"
  for i in $(seq -w 1 25); do : > "$d/oracle-ops-installer-202601${i}T000000Z-1.log"; done
  echo keep > "$d/admin-notes.txt"
  input 5
  run_installer
  assert_rc 0
  [ "$(find "$d" -name 'oracle-ops-installer-*.log' | wc -l)" = 20 ] || fail "expected 20 logs to be kept"
  assert_exists "$d/admin-notes.txt"
  assert_absent "$d/oracle-ops-installer-20260101T000000Z-1.log"
}

# ---- runner ----------------------------------------------------------------------------------------------------------------

main_tests() {
  local t rc passed=0 failed=0 names="" only="${1:-}"
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/oracle-ops-installer-tests.XXXXXX")"
  make_fixture || { echo "cannot create the fixture repository"; exit 1; }
  for t in $(declare -F | awk '{ print $3 }' | grep '^test_'); do
    [ -z "$only" ] || [ "$t" = "$only" ] || continue
    ( new_sandbox; "$t" ) > "$TEST_ROOT/$t.out" 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then passed=$((passed + 1)); printf 'PASS %s\n' "$t"
    else failed=$((failed + 1)); names="$names $t"; printf 'FAIL %s\n' "$t"; sed 's/^/    /' "$TEST_ROOT/$t.out" | tail -n 80; fi
  done
  echo
  printf 'installer tests: %d passed, %d failed\n' "$passed" "$failed"
  [ "$failed" = 0 ] && rm -rf -- "$TEST_ROOT"
  [ "$failed" = 0 ] || { echo "failed:$names"; echo "artifacts: $TEST_ROOT"; exit 1; }
}

main_tests "$@"
